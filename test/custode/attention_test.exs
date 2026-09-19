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
