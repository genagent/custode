defmodule Custode.AttentionTest do
  use ExUnit.Case, async: true

  alias Custode.Attention
  alias Custode.Signal

  doctest Custode.Attention
  doctest Custode.Signal

  @now ~U[2026-07-26 02:00:00Z]
  @context %{now: @now}

  defp view(id, fields) do
    Enum.into(fields, %{id: id, state: :offline})
  end

  defp gate(kind, opened_at, fields \\ []) do
    Enum.into(fields, %{kind: kind, detail: nil, action_id: nil, opened_at: opened_at})
  end

  defp resolve(view), do: Attention.resolve(view, @context)

  defp pr(number, disowned? \\ false), do: %{number: number, disowned?: disowned?}

  describe "disowned_check (#313)" do
    test "a red check the agent disowned is the operator's, not the fleet's" do
      signal = resolve(view("mdbook-lint", failing_prs: [pr(400, true)]))

      assert signal.kind == :disowned_check
      assert signal.group == :needs_you
      assert Signal.needs_you?(signal)
      assert signal.headline == "#400 red, and not its work"
      assert signal.detail =~ "nobody else will"
      assert signal.item == {:prs, [400]}
    end

    test "the same check, still owned, stays in watching" do
      signal = resolve(view("mdbook-lint", failing_prs: [pr(400, false)]))

      assert signal.kind == :red_check
      assert signal.group == :watching
    end

    test "one disowned PR among owned ones wins, since it is the stuck one" do
      signal = resolve(view("mixed", failing_prs: [pr(1), pr(2, true), pr(3)]))

      assert signal.kind == :disowned_check
      assert signal.item == {:prs, [2]}
    end

    test "disowning a PR whose checks are green raises nothing at all" do
      # a disownment is not itself a signal; only a red check on one is
      assert resolve(view("quiet-repo", failing_prs: [], cron: "@daily")).kind == :scheduled
    end

    test "it outranks a plain red check across agents, and both sit below a gate" do
      signals = [
        resolve(view("owned", failing_prs: [pr(1)])),
        resolve(view("disowned", failing_prs: [pr(2, true)])),
        resolve(view("gated", state: :awaiting_permission, gate: gate("approval", @now)))
      ]

      assert Attention.rank(signals) |> Enum.map(& &1.subject) == ["gated", "disowned", "owned"]
    end
  end

  describe "turn_failing (#527)" do
    defp failed(category, failures, fields \\ []) do
      Enum.into(fields, %{
        category: category,
        failures: failures,
        detail: "exit 1: Invalid API key",
        since: ~U[2026-07-26 01:15:00Z]
      })
    end

    test "one auth failure says what the operator must do" do
      signal = resolve(view("redisctl", cron: "@daily", turn_failure: failed(:auth_failed, 1)))

      assert signal.kind == :turn_failing
      assert signal.group == :needs_you
      assert signal.urgency == :high
      assert signal.headline =~ "claude is not logged in on this host"
      assert signal.detail == "1 failed turn (auth_failed): exit 1: Invalid API key"

      assert signal.item ==
               {:turn_failure,
                %{
                  category: :auth_failed,
                  failures: 1,
                  retryable: false,
                  detail: "exit 1: Invalid API key"
                }}

      assert signal.raised_at == ~U[2026-07-26 01:15:00Z]
      assert [%{label: "Inspect", op: :open_agent, args: %{agent: "redisctl"}}] = signal.resolving
    end

    test "a config error is a fact about the host too, so one is enough" do
      assert resolve(view("a", turn_failure: failed(:config_error, 1))).kind == :turn_failing
    end

    test "one crash or one refused cap can be one bad turn; the second in a row is not" do
      for category <- [:process_crash, :capability_refused] do
        once = view("a", cron: "@daily", turn_failure: failed(category, 1))
        twice = view("a", cron: "@daily", turn_failure: failed(category, 2))

        assert resolve(once).kind == :scheduled
        assert resolve(twice).kind == :turn_failing
        assert resolve(twice).detail =~ "2 failed turns"
      end
    end

    test "no failure fact, no signal" do
      assert resolve(view("a", cron: "@daily", turn_failure: nil)).kind == :scheduled
    end

    test "it outranks a question and a gate: answering only starts a turn that fails again" do
      failure = failed(:auth_failed, 3)
      ask = %{id: 1, question: "which branch?", blocking: false, asked_at: @now}

      asked = view("a", ask: ask, turn_failure: failure)

      gated =
        view("b",
          state: :awaiting_permission,
          gate: gate("approval", @now),
          turn_failure: failure
        )

      assert resolve(asked).kind == :turn_failing
      assert resolve(gated).kind == :turn_failing
    end

    test "it ranks right after a red branch" do
      kinds = Attention.kinds()
      index = Enum.find_index(kinds, &(&1 == :turn_failing))

      assert Enum.at(kinds, index - 1) == :red_main
      assert Enum.at(kinds, index + 1) == :needs_answer
    end

    test "a failure with no detail still reads as a sentence" do
      signal = resolve(view("a", turn_failure: failed(:auth_failed, 1, detail: nil)))

      assert signal.detail == "1 failed turn (auth_failed)"
    end
  end

  describe "sensor_failing (#444)" do
    defp streak(id, failures, fields \\ []) do
      Enum.into(fields, %{
        id: id,
        failures: failures,
        last_error: "Resource protected by organization SAML enforcement",
        since: ~U[2026-07-26 01:15:00Z]
      })
    end

    test "three failed runs in a row name the sensor and the error" do
      signal = resolve(view("redisctl", sensor_failures: [streak("ci-redisctl", 3)]))

      assert signal.kind == :sensor_failing
      assert signal.urgency == :normal

      assert signal.headline ==
               "ci-redisctl has failed 3 runs: Resource protected by organization SAML enforcement"

      assert signal.detail =~ "ci-redisctl (3 runs)"
      assert signal.item == {:sensors, ["ci-redisctl"]}
      assert [%{label: "Inspect", op: :open_agent, args: %{agent: "redisctl"}}] = signal.resolving
    end

    test "it sits in watching: a channel is dark, the operator is not blocked" do
      signal = resolve(view("redisctl", sensor_failures: [streak("ci-redisctl", 9)]))

      assert signal.group == :watching
      refute Signal.needs_you?(signal)
    end

    test "below the threshold a failure is a blip and raises nothing" do
      view = view("redisctl", cron: "@daily", sensor_failures: [streak("ci-redisctl", 2)])

      assert resolve(view).kind == :scheduled
    end

    test "the threshold comes from the context, because the resolver reads no config" do
      view = view("redisctl", cron: "@daily", sensor_failures: [streak("ci-redisctl", 2)])

      assert Attention.resolve(view, Map.put(@context, :sensor_failure_threshold, 2)).kind ==
               :sensor_failing

      assert Attention.resolve(view, Map.put(@context, :sensor_failure_threshold, 5)).kind ==
               :scheduled
    end

    test "it is dated from the start of the streak, so an older outage ranks first" do
      older = streak("ci-a", 40, since: ~U[2026-07-25 09:00:00Z])
      newer = streak("ci-b", 3, since: ~U[2026-07-26 01:15:00Z])

      signals = [
        resolve(view("b", sensor_failures: [newer])),
        resolve(view("a", sensor_failures: [older]))
      ]

      assert hd(signals).raised_at == ~U[2026-07-26 01:15:00Z]
      assert Attention.rank(signals) |> Enum.map(& &1.subject) == ["a", "b"]
    end

    test "several failing sensors on one agent are one signal that names them all" do
      signal =
        resolve(
          view("watcher",
            sensor_failures: [
              streak("quakes", 4, since: ~U[2026-07-26 00:00:00Z]),
              streak("ci-x", 12, since: ~U[2026-07-25 00:00:00Z]),
              streak("blip", 1)
            ]
          )
        )

      assert signal.headline == "2 sensors are failing: ci-x, quakes"
      assert signal.item == {:sensors, ["ci-x", "quakes"]}
      assert signal.raised_at == ~U[2026-07-25 00:00:00Z]
      refute signal.detail =~ "blip"
    end

    test "it ranks right after a red check and ahead of a reached rail" do
      kinds = Attention.kinds()
      index = Enum.find_index(kinds, &(&1 == :sensor_failing))

      assert Enum.at(kinds, index - 1) == :red_check
      assert Enum.at(kinds, index + 1) == :rail_hit
      assert hd(kinds) == :host_down
    end

    test "a red check on the same agent wins, and a gate wins over both" do
      failing = [streak("ci-redisctl", 3)]

      assert resolve(view("a", sensor_failures: failing, failing_prs: [pr(1)])).kind == :red_check

      gated =
        view("a",
          sensor_failures: failing,
          state: :awaiting_permission,
          gate: gate("approval", @now)
        )

      assert resolve(gated).kind == :approval
    end

    test "a long error is clipped in the headline and whole in the detail" do
      error = String.duplicate("e", 200)
      signal = resolve(view("a", sensor_failures: [streak("s", 3, last_error: error)]))

      assert String.length(signal.headline) < 120
      assert signal.detail =~ error
    end
  end

  describe "workflows/1 (#447)" do
    defp launch(id, fields \\ []) do
      Enum.into(fields, %{
        id: id,
        workflow: "backlog-mine",
        repo: "acme/widgets",
        summary: "run backlog-mine on acme/widgets: 3 nodes, ~$0.90, rail $5.00",
        why: "the board is dry",
        proposed_at: ~U[2026-07-26 01:00:00Z]
      })
    end

    defp paused(run_id, fields \\ []) do
      Enum.into(fields, %{
        run_id: run_id,
        workflow: "backlog-mine",
        repo: "acme/widgets",
        reason: "run budget rail hit: $1.20 of $1.00; paused before merge",
        paused_at: ~U[2026-07-26 01:30:00Z]
      })
    end

    test "a launch proposal is owed to the operator, with approve and reject to clear it" do
      assert [signal] = Attention.workflows(%{launches: [launch("wfl-1")], paused_runs: []})

      assert signal.kind == :workflow_launch
      assert signal.group == :needs_you
      assert Signal.needs_you?(signal)
      assert signal.subject == "backlog-mine on acme/widgets"
      assert signal.headline == "wants your approval to launch"
      assert signal.detail =~ "the board is dry"
      assert signal.detail =~ "rail $5.00"
      assert signal.item == {:proposal, "wfl-1"}
      assert signal.raised_at == ~U[2026-07-26 01:00:00Z]

      assert [
               %{label: "Approve", op: :approve_launch, args: %{proposal: "wfl-1"}},
               %{label: "Reject", op: :reject_launch, args: %{proposal: "wfl-1"}},
               %{op: :open_workflows}
             ] = signal.resolving
    end

    test "a proposal nobody explained still reads as a sentence" do
      assert [signal] =
               Attention.workflows(%{launches: [launch("wfl-1", why: nil)], paused_runs: []})

      assert signal.detail == "run backlog-mine on acme/widgets: 3 nodes, ~$0.90, rail $5.00"
    end

    test "a run parked on its rail offers the raise, and says what it did not run" do
      assert [signal] = Attention.workflows(%{launches: [], paused_runs: [paused("run-9")]})

      assert signal.kind == :workflow_rail
      assert signal.group == :needs_you
      assert signal.headline == "run run-9 is parked on its budget rail"
      assert signal.detail =~ "paused before merge"
      assert signal.item == {:run, "run-9"}
      assert signal.raised_at == ~U[2026-07-26 01:30:00Z]

      assert [
               %{label: "Raise the rail and resume", op: :resume_run, args: %{run: "run-9"}},
               %{op: :open_workflows}
             ] = signal.resolving
    end

    test "every proposal and every parked run is its own signal" do
      facts = %{
        launches: [launch("wfl-1"), launch("wfl-2", repo: "acme/gears")],
        paused_runs: [paused("run-9")]
      }

      assert facts |> Attention.workflows() |> Enum.map(& &1.item) == [
               {:proposal, "wfl-1"},
               {:proposal, "wfl-2"},
               {:run, "run-9"}
             ]
    end

    test "a launch ranks with the approvals and a parked run with the rails, oldest first" do
      [new_launch, old_launch] =
        Attention.workflows(%{
          launches: [
            launch("wfl-new", repo: "acme/new", proposed_at: ~U[2026-07-26 01:50:00Z]),
            launch("wfl-old", repo: "acme/old", proposed_at: ~U[2026-07-24 09:00:00Z])
          ],
          paused_runs: []
        })

      [rail] = Attention.workflows(%{launches: [], paused_runs: [paused("run-9")]})
      gated = resolve(view("gated", state: :awaiting_permission, gate: gate("approval", @now)))
      spent = resolve(view("spent", spend_today: 450.0, budget: 450.0))
      red = resolve(view("red", failing_prs: [pr(1)]))

      assert Attention.rank([red, rail, spent, new_launch, gated, old_launch])
             |> Enum.map(& &1.subject) == [
               "gated",
               "backlog-mine on acme/old",
               "backlog-mine on acme/new",
               "spent",
               "backlog-mine on acme/widgets",
               "red"
             ]
    end
  end

  describe "red_main (#310)" do
    defp branch(state), do: %{name: "main", state: state, headline: "the merge that broke it"}

    test "a failing default branch outranks everything, including a question" do
      signal =
        resolve(
          view("custode-dev",
            state: :waiting_for_user,
            gate: gate("question", @now),
            default_branch: branch("FAILURE")
          )
        )

      assert signal.kind == :red_main
      assert signal.group == :needs_you
      assert signal.urgency == :high
      assert signal.headline == "main is red"
      assert signal.detail == "the merge that broke it"
      assert signal.item == {:branch, "main"}
    end

    test "ERROR counts as red too" do
      assert resolve(view("a", default_branch: branch("ERROR"))).kind == :red_main
    end

    test "a green branch is not a signal" do
      assert resolve(view("a", default_branch: branch("SUCCESS"))).kind != :red_main
    end

    test "unknown is not red -- an empty repo and an unreported rollup both land here" do
      for state <- [nil, "PENDING", "EXPECTED"] do
        refute resolve(view("a", default_branch: branch(state))).kind == :red_main
      end

      refute resolve(view("a", default_branch: nil)).kind == :red_main
    end

    test "it ranks above a question on another agent" do
      signals = [
        resolve(view("asker", state: :waiting_for_user, gate: gate("question", @now))),
        resolve(view("broken", default_branch: branch("FAILURE")))
      ]

      assert Attention.rank(signals) |> Enum.map(& &1.subject) == ["broken", "asker"]
    end
  end

  describe "resolving ops a surface can perform (#449)" do
    # "Re-run checks" was offered on three signals and handled nowhere, so the
    # inbox drew it as a link to the agent page under a label that promised a
    # re-run. Until the verb exists the three offer only the navigation op.
    test "red_main offers only opening the agent" do
      signal =
        resolve(view("a", default_branch: %{name: "main", state: "FAILURE", headline: "x"}))

      assert signal.kind == :red_main
      assert [%{label: "Open agent", op: :open_agent, args: %{agent: "a"}}] = signal.resolving
    end

    test "disowned_check offers only inspecting the agent" do
      signal = resolve(view("a", failing_prs: [pr(400, true)]))

      assert signal.kind == :disowned_check
      assert [%{label: "Inspect", op: :open_agent, args: %{agent: "a"}}] = signal.resolving
    end

    test "red_check offers only inspecting the agent" do
      signal = resolve(view("a", failing_prs: [pr(187)]))

      assert signal.kind == :red_check
      assert [%{label: "Inspect", op: :open_agent, args: %{agent: "a"}}] = signal.resolving
    end
  end

  describe "needs_answer from a non-blocking ask (#299)" do
    test "an open ask raises the signal whatever the agent is doing" do
      ask = %{id: 7, question: "is the uncommitted diff yours?", asked_at: @now}

      # The point of the change: asking did not stop the agent, so it is idle
      # or working, and the question is still owed.
      for state <- [:idle, :running, :offline] do
        signal = resolve(view("adrs", state: state, cron: "*/30 * * * *", ask: ask))

        assert signal.kind == :needs_answer
        assert signal.group == :needs_you
        assert signal.headline == "asked you a question"
        assert signal.detail == "is the uncommitted diff yours?"
        assert signal.item == {:ask, 7}
        assert signal.raised_at == @now
        assert [%{label: "Answer", op: :answer_ask, args: %{ask: 7}} | _rest] = signal.resolving
      end
    end

    test "an ask outranks a gate on the same agent, since it came from further back" do
      ask = %{id: 7, question: "still curious?", asked_at: ~U[2026-07-26 00:00:00Z]}
      view = view("both", state: :awaiting_permission, gate: gate("approval", @now), ask: ask)

      assert resolve(view).item == {:ask, 7}
    end

    test "a blocking question says so, because a parked agent is worse" do
      signal =
        resolve(view("adrs", state: :waiting_for_user, gate: gate("question", @now)))

      assert signal.kind == :needs_answer
      assert signal.headline == "asked you a question and stopped"
    end
  end

  describe "resolve/2 -- one signal per kind" do
    test "needs_answer when the agent asked a question and parked" do
      signal =
        resolve(
          view("adrs",
            state: :waiting_for_user,
            gate: gate("question", ~U[2026-07-26 00:53:27Z], detail: "Is this yours to touch?")
          )
        )

      assert signal.kind == :needs_answer
      assert signal.group == :needs_you
      assert signal.urgency == :high
      assert signal.headline == "asked you a question and stopped"
      assert signal.detail == "Is this yours to touch?"
      assert signal.raised_at == ~U[2026-07-26 00:53:27Z]
      assert [%{label: "Answer", op: :answer} | _rest] = signal.resolving
    end

    test "approval when a gate is open, carrying the action id the button needs" do
      signal =
        resolve(
          view("git-spawn",
            state: :awaiting_permission,
            gate: gate("approval", ~U[2026-07-26 01:30:39Z], action_id: "act_14274")
          )
        )

      assert signal.kind == :approval
      assert signal.group == :needs_you
      assert signal.item == "act_14274"

      assert [%{op: :approve, args: %{action: "act_14274"}}, %{op: :reject} | _rest] =
               signal.resolving
    end

    test "an approval left by an offline provider offers recovery instead of approval" do
      signal =
        resolve(
          view("git-spawn",
            state: :offline,
            gate: gate("approval", @now, action_id: "act_departed")
          )
        )

      assert signal.kind == :approval
      assert signal.headline == "approval needs recovery"
      assert [%{label: "Requeue", op: :recover_gate}, %{op: :open_agent}] = signal.resolving
      refute Enum.any?(signal.resolving, &(&1.op in [:approve, :reject]))
    end

    test "a durable gate for a different action is never offered as the live approval" do
      signal =
        resolve(
          view("git-spawn",
            state: :awaiting_permission,
            live_action_id: "act_current",
            gate: gate("approval", @now, action_id: "act_departed")
          )
        )

      assert [%{op: :recover_gate, args: %{action: "act_departed"}} | _rest] = signal.resolving
    end

    test "an approval says which class of action it is, when the agent declared one (#451)" do
      gated = fn fields ->
        resolve(
          view("git-spawn",
            state: :awaiting_permission,
            gate: gate("approval", ~U[2026-07-26 01:30:39Z], [action_id: "act_1"] ++ fields)
          )
        )
      end

      assert gated.(class: "ready_pr").headline == "wants your approval (ready_pr)"
      assert gated.(class: nil).headline == "wants your approval"
      assert gated.([]).headline == "wants your approval"
    end

    test "an approval includes the other provider's typed review evidence" do
      signal =
        resolve(
          view("git-spawn",
            state: :awaiting_permission,
            gate:
              gate("approval", @now,
                action_id: "act_1",
                review_state: "completed",
                review: %{
                  provider: "codex",
                  summary: "one warning",
                  findings: [
                    %{
                      "severity" => "WARN",
                      "claim" => "edge case is uncovered",
                      "evidence" => %{
                        "files" => [%{"path" => "diff.patch", "lines" => "1-3"}]
                      }
                    }
                  ]
                }
              )
          )
        )

      assert signal.detail =~ "codex review: one warning"
      assert signal.detail =~ "WARN: edge case is uncovered (diff.patch:1-3)"
    end

    test "needs_answer outranks approval when both could apply" do
      signal =
        resolve(view("both", state: :waiting_for_user, gate: gate("approval", @now)))

      assert signal.kind == :needs_answer
    end

    test "red_check names the PRs and stays in watching" do
      signal = resolve(view("mcp-proxy", failing_prs: [pr(187), pr(190)]))

      assert signal.kind == :red_check
      assert signal.urgency == :normal
      # Watching, NOT needs-you: a scheduled agent looks at its own red check
      # on the next beat, so the operator is not owed anything.
      assert signal.group == :watching
      refute Signal.needs_you?(signal)
      # named, because "#187 red" says which tab to open and a count does not
      assert signal.headline == "#187, #190 red on its open PRs"
      # The overview cache cannot date a check result. See the moduledoc.
      assert signal.raised_at == nil
    end

    test "rail_hit only at the rail, not approaching it" do
      assert resolve(view("thrifty", spend_today: 23.64, budget: 450.0)).kind != :rail_hit
      assert resolve(view("near", spend_today: 449.0, budget: 450.0)).kind != :rail_hit

      signal = resolve(view("spent", spend_today: 450.0, budget: 450.0))
      assert signal.kind == :rail_hit
      assert signal.detail == "spent $450.00 of $450.00"
    end

    test "rail_hit is skipped when the agent has no budget" do
      assert resolve(view("unbudgeted", spend_today: 99.0, budget: nil)).kind != :rail_hit
    end

    test "stalled is defined but never resolved -- deliberately unimplemented" do
      assert :stalled in Attention.kinds()

      signals =
        for state <- [:idle, :running, :offline, :paused], do: resolve(view("a", state: state))

      refute Enum.any?(signals, &(&1.kind == :stalled))
    end

    test "working while a turn is in flight, with elapsed in the detail" do
      signal =
        resolve(view("custode-dev", state: :running, running_since: ~U[2026-07-26 01:58:00Z]))

      assert signal.kind == :working
      assert signal.group == :working
      assert signal.detail == "started 2m ago"
    end

    test "paused is quiet, never a problem" do
      signal = resolve(view("stopped", state: :paused, cron: "*/30 * * * *"))

      assert signal.kind == :paused
      assert signal.group == :quiet
      refute Signal.needs_you?(signal)
      assert [%{op: :resume}] = signal.resolving
    end

    test "a paused agent is not reported as scheduled even though it has a cron" do
      # The departure from the design note's precedence: testing :scheduled
      # first would count a stopped agent down to a beat it will never run.
      assert resolve(view("stopped", state: :paused, cron: "@daily")).kind == :paused
    end

    test "offline with a cron is scheduled -- how a cold-start routine rests" do
      signal = resolve(view("mdbook-lint", state: :offline, cron: "@daily"))

      assert signal.kind == :scheduled
      assert signal.group == :scheduled
      assert signal.headline == "next beat @daily"
      # no gatherer fact, no guess
      assert signal.item == nil
    end

    test "a scheduled signal carries when the next beat is, as a time and not as words" do
      at = ~U[2026-09-21 07:00:00Z]
      signal = resolve(view("mdbook-lint", state: :offline, cron: "@daily", next_beat_at: at))

      assert signal.item == {:next_beat, at}
      assert signal.headline == "next beat @daily"
    end

    test "offline without a real cron is quiet" do
      for cron <- [nil, "", "manual"] do
        assert resolve(view("quakes", state: :offline, cron: cron)).kind == :quiet
      end
    end

    test "idle with nothing to say is quiet" do
      assert resolve(view("tower-resilience", state: :idle)).kind == :quiet
    end
  end

  describe "rank/1 against the live fleet of 2026-07-26" do
    # Six agents needing the operator, taken off the running fleet with their
    # real gate timestamps. The page at the time drew them in the order
    # commented beside each one: newest first, both questions below all four
    # approvals, and the oldest unanswered question last of the six.
    defp live_fleet do
      [
        # drawn 6th
        view("adrs", state: :waiting_for_user, gate: gate("question", ~U[2026-07-26 00:53:27Z])),
        # drawn 2nd
        view("redisctl",
          state: :awaiting_permission,
          gate: gate("approval", ~U[2026-07-26 01:11:39Z])
        ),
        # drawn 5th
        view("redis-tower",
          state: :waiting_for_user,
          gate: gate("question", ~U[2026-07-26 01:30:24Z])
        ),
        # drawn 3rd
        view("tower-mcp",
          state: :awaiting_permission,
          gate: gate("approval", ~U[2026-07-26 01:30:30Z])
        ),
        # drawn 4th
        view("git-spawn",
          state: :awaiting_permission,
          gate: gate("approval", ~U[2026-07-26 01:30:39Z])
        ),
        # drawn 1st
        view("codex_wrapper_ex",
          state: :awaiting_permission,
          gate: gate("approval", ~U[2026-07-26 01:30:55Z])
        ),
        view("custode-dev", state: :idle, cron: "*/15 * * * *"),
        view("mdbook-lint", state: :offline, cron: "@daily", failing_prs: [pr(400)]),
        view("mcp-proxy", state: :offline, cron: "@daily", failing_prs: [pr(187)]),
        view("quakes", state: :offline, cron: "manual"),
        view("tower-resilience", state: :idle, cron: "*/30 * * * *"),
        view("cheer", state: :offline, cron: "@daily")
      ]
    end

    defp ranked_ids(views) do
      views
      |> Enum.map(&Attention.resolve(&1, @context))
      |> Attention.rank()
      |> Enum.map(& &1.subject)
    end

    test "questions rise above approvals, and inside each kind the oldest rises" do
      assert ranked_ids(live_fleet()) |> Enum.take(6) == [
               "adrs",
               "redis-tower",
               "redisctl",
               "tower-mcp",
               "git-spawn",
               "codex_wrapper_ex"
             ]
    end

    test "the ranking is not the order the page drew, but close to its reverse" do
      drawn = ~w(codex_wrapper_ex redisctl tower-mcp git-spawn redis-tower adrs)
      assert ranked_ids(live_fleet()) |> Enum.take(6) != drawn
    end

    test "ranking is stable regardless of input order" do
      shuffled = Enum.shuffle(live_fleet())
      assert ranked_ids(shuffled) == ranked_ids(live_fleet())
    end

    test "red checks sit between the gates and the healthy, in their own group" do
      ranked = ranked_ids(live_fleet())
      reds = ["mdbook-lint", "mcp-proxy"]

      # below every gate, because nobody is blocked on the operator for them
      for red <- reds, gated <- ~w(adrs redis-tower redisctl codex_wrapper_ex) do
        assert index(ranked, gated) < index(ranked, red)
      end

      # and above everything with nothing to report at all
      for red <- reds, calm <- ~w(custode-dev quakes cheer) do
        assert index(ranked, red) < index(ranked, calm)
      end
    end

    test "an id breaks a tie so the order never flickers between renders" do
      same = ~U[2026-07-26 01:00:00Z]

      views = [
        view("zulu", state: :waiting_for_user, gate: gate("question", same)),
        view("alpha", state: :waiting_for_user, gate: gate("question", same))
      ]

      assert ranked_ids(views) == ["alpha", "zulu"]
    end

    defp index(list, value), do: Enum.find_index(list, &(&1 == value))
  end

  describe "by_group/1" do
    test "buckets in page order and drops empty groups" do
      grouped =
        live_fleet()
        |> Enum.map(&Attention.resolve(&1, @context))
        |> Attention.by_group()

      assert Enum.map(grouped, &elem(&1, 0)) == [:needs_you, :watching, :scheduled, :quiet]

      {:needs_you, needs_you} = List.keyfind(grouped, :needs_you, 0)
      assert length(needs_you) == 6
      assert Enum.all?(needs_you, &Signal.needs_you?/1)

      # the two red checks, and nothing else, are merely being watched
      {:watching, watching} = List.keyfind(grouped, :watching, 0)
      assert Enum.map(watching, & &1.subject) == ["mcp-proxy", "mdbook-lint"]
      refute Enum.any?(watching, &Signal.needs_you?/1)
    end

    test "quiet collapses the deliberately stopped and the genuinely idle together" do
      grouped =
        [view("paused", state: :paused), view("manual", state: :offline, cron: "manual")]
        |> Enum.map(&Attention.resolve(&1, @context))
        |> Attention.by_group()

      assert [{:quiet, [_paused, _manual]}] = grouped
    end
  end

  describe "purity" do
    test "resolve/2 defaults its own clock but never needs one for a gate signal" do
      view = view("adrs", state: :waiting_for_user, gate: gate("question", @now))

      assert Attention.resolve(view) == Attention.resolve(view, @context)
    end

    test "every kind maps to a group" do
      for kind <- Attention.kinds() do
        assert Attention.group_of(kind) in Attention.groups()
      end
    end
  end
end
