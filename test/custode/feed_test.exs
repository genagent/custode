defmodule Custode.FeedTest do
  # The feed handlers are attached globally at app boot and the path is read
  # per write, so each test points :feed_path at its own tmp file.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Feed.Ingest
  alias ObanClaude.Agent

  doctest Custode.Feed

  setup do
    path = Path.join(System.tmp_dir!(), uid("feed") <> ".jsonl")
    put_env!(:feed_path, path)

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".1")
    end)

    %{path: path}
  end

  test "transactional events publish only after commit and roll back without side effects", %{
    path: path
  } do
    agent = uid("transactional-feed")
    Custode.PubSubBridge.subscribe()

    assert {:error, :cancel} =
             Custode.Repo.transaction(fn ->
               assert {:ok, _entry} =
                        Custode.Feed.record_in_transaction(%{
                          event: "peer_message_sent",
                          agent: agent
                        })

               refute File.exists?(path)
               refute_receive {:feed_entry, _}, 10
               Custode.Repo.rollback(:cancel)
             end)

    assert Custode.Feed.for_agent(agent) == []
    refute File.exists?(path)

    assert {:ok, entry} =
             Custode.Repo.transaction(fn ->
               {:ok, entry} =
                 Custode.Feed.record_in_transaction(%{event: "peer_message_sent", agent: agent})

               entry
             end)

    assert [^entry] = Custode.Feed.for_agent(agent)
    refute File.exists?(path)
    assert :ok = Custode.Feed.publish_committed(entry)
    assert_receive {:feed_entry, ^entry}
    assert File.read!(path) =~ agent
    assert [^entry] = Custode.Feed.for_agent(agent)
  end

  defp job_meta(agent_id), do: %Oban.Job{meta: %{"agent_id" => agent_id}}

  test "a finished run writes a turn entry with directive, summary, and spend" do
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: job_meta("feed-a"),
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => "swept"}, cost_usd: 0.2)
          )
      )

    assert [entry] = Custode.Feed.for_agent("feed-a")
    assert %{"event" => "turn", "agent" => "feed-a", "summary" => "swept"} = entry
    assert_in_delta entry["cost_usd"], 0.2, 0.001
    # a scheduled sweep stays summary-only (#138)
    assert entry["response"] == nil
  end

  test "a finished Codex run writes the same turn entry shape" do
    {:ok, _} =
      ObanCodex.run(%{"prompt" => "x"},
        job: job_meta("feed-codex"),
        query_fun:
          ObanCodex.Testing.respond(
            ObanCodex.Testing.structured_result(
              %{"directive" => "none", "summary" => "reviewed"},
              usage: %{"input_tokens" => 12, "output_tokens" => 5}
            )
          )
      )

    assert [entry] = Custode.Feed.for_agent("feed-codex")
    assert %{"event" => "turn", "agent" => "feed-codex", "summary" => "reviewed"} = entry
    assert entry["tokens"] == 17
  end

  test "turns record the provider's actual continuation decision and packet fallback" do
    for {agent, args, decision, expected} <- [
          {"feed-resume", %{"prompt" => "x", "custode_context_path" => "/tmp/HANDOFF.md"},
           "resume", "native_resume"},
          {"feed-packet", %{"prompt" => "x", "custode_context_path" => "/tmp/HANDOFF.md"},
           "fresh_fallback", "packet"},
          {"feed-fresh", %{"prompt" => "x"}, "fresh", "fresh"}
        ] do
      {:ok, _} =
        ObanClaude.run(args,
          job: %Oban.Job{
            args: args,
            meta: %{"agent_id" => agent, "continuation_decision" => decision}
          },
          query_fun: respond(structured_result(%{"directive" => "none", "summary" => "done"}))
        )

      assert [%{"hydration" => ^expected}] = Custode.Feed.for_agent(agent)
    end
  end

  test "an inbox delivery turn records why the agent woke" do
    agent = uid("feed-inbox")

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{
          meta: %{
            "agent_id" => agent,
            "correlation_id" => "inbox:wake-id:claim-token"
          }
        },
        query_fun: respond(structured_result(%{"directive" => "none", "summary" => "read inbox"}))
      )

    assert [%{"wake_reason" => "inbox_activity"}] = Custode.Feed.for_agent(agent)
  end

  test "a cross-provider gate review is not recorded as a standing-agent turn" do
    result =
      ObanCodex.Testing.structured_result(%{
        "summary" => "one warning",
        "findings" => []
      })

    :ok =
      Ingest.handle_event(
        [:oban_codex, :run, :stop],
        %{cost_usd: 0.0},
        %{
          result: result,
          job: %{meta: %{"agent_id" => "review-author", "custode_kind" => "gate_review"}}
        },
        nil
      )

    assert Custode.Feed.for_agent("review-author") == []
  end

  describe "the schema'd epilogue (#120 slice 2)" do
    test "prs and issues_touched land on the turn entry as typed arrays" do
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-epi"),
          query_fun:
            respond(
              structured_result(%{
                "directive" => "none",
                "summary" => "opened the fix",
                "prs" => [169, 171],
                "issues_touched" => [31]
              })
            )
        )

      assert [entry] = Custode.Feed.for_agent("feed-epi")
      # numbers, not prose: a consumer reads the field instead of the summary
      assert entry["prs"] == [169, 171]
      assert entry["issues_touched"] == [31]
    end

    test "a turn that touched nothing carries neither key" do
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-bare"),
          query_fun:
            respond(structured_result(%{"directive" => "none", "summary" => "read only"}))
        )

      assert [entry] = Custode.Feed.for_agent("feed-bare")
      refute Map.has_key?(entry, "prs")
      refute Map.has_key?(entry, "issues_touched")
    end

    test "an unschema'd turn and a malformed epilogue both keep the old shape" do
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-prose"),
          query_fun: respond(result(result: "just prose, no structure"))
        )

      # a model that sends the wrong type must not put junk on the entry, and
      # must not take the handler down with it
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-junk"),
          query_fun:
            respond(
              structured_result(%{
                "directive" => "none",
                "summary" => "wrong types",
                "prs" => "#169",
                "issues_touched" => [31, "thirty-two"]
              })
            )
        )

      assert [prose] = Custode.Feed.for_agent("feed-prose")
      refute Map.has_key?(prose, "prs")

      assert [junk] = Custode.Feed.for_agent("feed-junk")
      refute Map.has_key?(junk, "prs")
      assert junk["issues_touched"] == [31]
      assert junk["summary"] == "wrong types"
    end
  end

  defp backdate_last!(days) do
    [[id]] = Custode.Repo.query!("SELECT id FROM feed_entries ORDER BY id DESC LIMIT 1").rows
    at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()
    Custode.Repo.query!("UPDATE feed_entries SET at = ? WHERE id = ?", [at, id])
  end

  describe "recent_by_event/2 (#178)" do
    test "returns only that event, newest first, capped by :limit" do
      agent = uid("rbe")

      Custode.Feed.record(%{event: "advisor_suggestion", agent: agent, field: "cron"})
      Custode.Feed.record(%{event: "turn", agent: agent, summary: "unrelated"})
      Custode.Feed.record(%{event: "advisor_suggestion", agent: agent, field: "budget"})

      # cards, not a timeline: the freshest suggestion comes back first
      assert [%{"field" => "budget"}, %{"field" => "cron"}] =
               Custode.Feed.recent_by_event("advisor_suggestion", agent: agent)

      assert [%{"field" => "budget"}] =
               Custode.Feed.recent_by_event("advisor_suggestion", agent: agent, limit: 1)
    end

    test ":agent scopes to one agent and :since drops anything older" do
      mine = uid("rbe-mine")
      theirs = uid("rbe-theirs")

      Custode.Feed.record(%{event: "advisor_suggestion", agent: mine, field: "stale"})
      backdate_last!(30)
      Custode.Feed.record(%{event: "advisor_suggestion", agent: mine, field: "fresh"})
      Custode.Feed.record(%{event: "advisor_suggestion", agent: theirs, field: "elsewhere"})

      fleet = Custode.Feed.recent_by_event("advisor_suggestion", since: 7 * 24 * 60 * 60)
      fields = Enum.map(fleet, & &1["field"])
      assert "fresh" in fields
      assert "elsewhere" in fields
      refute "stale" in fields

      assert [%{"field" => "fresh"}] =
               Custode.Feed.recent_by_event("advisor_suggestion",
                 agent: mine,
                 since: 7 * 24 * 60 * 60
               )
    end

    test ":now makes a since-window independent of the wall clock" do
      reference = ~U[2020-01-10 12:00:00Z]
      agent = uid("rbe-clock")

      Custode.Feed.record(%{event: "advisor_suggestion", agent: agent, field: "fixed"})

      [[id]] = Custode.Repo.query!("SELECT id FROM feed_entries ORDER BY id DESC LIMIT 1").rows
      at = reference |> DateTime.add(-1, :day) |> DateTime.to_iso8601()
      Custode.Repo.query!("UPDATE feed_entries SET at = ? WHERE id = ?", [at, id])

      assert [%{"field" => "fixed"}] =
               Custode.Feed.recent_by_event("advisor_suggestion",
                 agent: agent,
                 since: 2 * 24 * 60 * 60,
                 now: reference
               )

      assert [] =
               Custode.Feed.recent_by_event("advisor_suggestion",
                 agent: agent,
                 since: 2 * 24 * 60 * 60,
                 now: DateTime.add(reference, 4, :day)
               )
    end

    test "an event nobody has recorded is an empty list, not a crash" do
      assert Custode.Feed.recent_by_event("no_such_event") == []
    end
  end

  test "an operator-origin turn persists the full answer on the entry (#138)" do
    answer = "Pros:\n- it fixes the bug\n\nCons:\n- semver surface"

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "tradeoffs of #937?"},
        job: %Oban.Job{meta: %{"agent_id" => "feed-q", "origin" => "operator"}},
        query_fun: respond(result(result: answer, cost_usd: 0.05))
      )

    assert [entry] = Custode.Feed.for_agent("feed-q")
    assert entry["event"] == "turn"
    # the answer survives on the durable entry -- a restart cannot strand it
    assert entry["response"] == answer

    # tick-origin explicitly marked also stays summary-only
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "sweep"},
        job: %Oban.Job{meta: %{"agent_id" => "feed-q", "origin" => "tick"}},
        query_fun: respond(result(result: "did the sweep", cost_usd: 0.01))
      )

    entries = Custode.Feed.for_agent("feed-q")
    assert length(entries) == 2
    # exactly the operator-origin turn carries a response, whatever the order
    assert [%{"response" => ^answer}] = Enum.filter(entries, & &1["response"])
  end

  test "an operator turn with structured output carries no response blob (#201)" do
    answer = "Pros: fixes the bug. Cons: binds the semver surface to schemars 1.x."

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "tradeoffs of #937?"},
        job: %Oban.Job{meta: %{"agent_id" => "feed-blob", "origin" => "operator"}},
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => answer}, cost_usd: 0.07)
          )
      )

    assert [entry] = Custode.Feed.for_agent("feed-blob")
    # the answer lives ONCE, in the summary; the raw directive JSON that a
    # schema'd run leaves in result.result never echoes as a response block
    assert entry["summary"] == answer
    assert entry["response"] == nil
  end

  for {provider, runner, fixtures} <- [
        {:claude, ObanClaude, ObanClaude.Testing},
        {:codex, ObanCodex, ObanCodex.Testing}
      ] do
    @provider provider
    @runner runner
    @fixtures fixtures

    test "#{provider} keeps a bounded Markdown answer separate from its interval report" do
      agent = uid("feed-answer-#{@provider}")
      answer = "## Findings\n\n" <> String.duplicate("- **Verified:** résumé is retained.\n", 700)
      report = %{"done" => ["Reviewed the design"], "next" => ["Choose the next step"]}

      output = %{
        "directive" => "none",
        "summary" => "Reviewed the design",
        "answer" => answer,
        "report" => report
      }

      assert {:ok, _} =
               @runner.run(%{"prompt" => "explain the design"},
                 job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "operator"}},
                 query_fun: @fixtures.respond(@fixtures.structured_result(output))
               )

      assert [entry] = Custode.Feed.for_agent(agent)
      assert entry["event"] == "turn"
      assert entry["summary"] == "Reviewed the design"
      assert entry["response"] == String.slice(answer, 0, 16_384)
      assert String.length(entry["response"]) == 16_384
      assert entry["report"]["done"] == report["done"]
      assert entry["report"]["next"] == report["next"]

      assert %{entries: [interval]} = Custode.IntervalReports.recent(agent)
      assert interval["summary"] == "Reviewed the design"
      assert interval["report"] == entry["report"]
      refute Map.has_key?(interval, "response")
      refute Jason.encode!(interval) =~ "résumé"
    end

    test "#{provider} omits answer previews for scheduled, report-only and legacy turns" do
      for {origin, fields} <- [
            {"tick", %{"answer" => "A scheduled answer must not become an operator reply"}},
            {"operator", %{"answer" => nil}},
            {"operator", %{"answer" => " \n "}},
            {"operator", %{}}
          ] do
        agent = uid("feed-no-answer-#{@provider}")

        output =
          Map.merge(
            %{
              "directive" => "none",
              "summary" => "Repository is healthy",
              "report" => %{"done" => ["Checked repository health"]}
            },
            fields
          )

        assert {:ok, _} =
                 @runner.run(%{"prompt" => "check health"},
                   job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => origin}},
                   query_fun: @fixtures.respond(@fixtures.structured_result(output))
                 )

        assert [entry] = Custode.Feed.for_agent(agent)
        assert entry["event"] == "turn"
        assert entry["summary"] == "Repository is healthy"
        assert entry["report"]["done"] == ["Checked repository health"]
        assert entry["response"] == nil
      end
    end

    test "#{provider} does not publish an answer or report from a failed structured result" do
      agent = uid("feed-failed-answer-#{@provider}")

      output = %{
        "directive" => "none",
        "summary" => "Unconfirmed completion",
        "answer" => "This proposed answer must not be published as a successful reply",
        "report" => %{"done" => ["Unconfirmed work"]}
      }

      result = @fixtures.structured_result(output)

      failed =
        case @provider do
          :claude -> %{result | is_error: true, result: "provider failed before completion"}
          :codex -> %{result | success: false, exit_code: 17, stderr: "provider failed"}
        end

      assert {{:error, _reason}, ^failed} =
               @runner.run(%{"prompt" => "explain the result"},
                 job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "operator"}},
                 query_fun: @fixtures.respond(failed)
               )

      assert [entry] = Custode.Feed.for_agent(agent)
      assert entry["event"] == "turn_failed"

      case @provider do
        :claude ->
          assert entry["detail"] =~ "provider failed"

        :codex ->
          assert entry["detail"] == "exit 17: Codex exited unsuccessfully without a diagnostic"
      end

      refute Map.has_key?(entry, "response")
      refute Map.has_key?(entry, "summary")
      refute Map.has_key?(entry, "report")
      assert %{entries: []} = Custode.IntervalReports.recent(agent)
    end
  end

  test "a failed run writes a turn_failed entry with the error kind AND its detail" do
    {{:error, :command_failed}, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: job_meta("feed-b"),
        query_fun:
          fail(error(:command_failed, message: "spawn refused", exit_code: 127, stderr: "boom"))
      )

    assert [entry] = Custode.Feed.for_agent("feed-b")
    assert %{"event" => "turn_failed", "agent" => "feed-b", "kind" => "command_failed"} = entry
    assert entry["detail"] =~ "exit 127"
    assert entry["detail"] =~ "spawn refused"
    assert entry["detail"] =~ "boom"
    # a bare non-zero exit has no typed cause (#527)
    assert entry["category"] == "unknown_harness_error"
    assert entry["retryable"] == true
  end

  test "a failed Codex result is recorded as a failure, not a successful turn" do
    {{:error, {:command_failed, 17}}, _} =
      ObanCodex.run(%{"prompt" => "x"},
        job: job_meta("feed-codex-failed"),
        query_fun:
          ObanCodex.Testing.respond(
            ObanCodex.Testing.failed_result("partial output",
              exit_code: 17,
              stderr: "codex failed"
            )
          )
      )

    assert [entry] = Custode.Feed.for_agent("feed-codex-failed")
    assert entry["event"] == "turn_failed"
    assert entry["kind"] == "command_failed"
    assert entry["category"] == "unknown_harness_error"
    assert entry["detail"] =~ "exit 17"
    assert entry["detail"] =~ "codex failed"
  end

  test "Codex stdout failure diagnostics are safe in storage, publication and the feed mirror", %{
    path: path
  } do
    agent = uid("feed-codex-diagnostic")
    Custode.PubSubBridge.subscribe()

    stdout =
      String.duplicate("startup metadata\n", 100) <>
        "Error: account rejected OPENAI_API_KEY='PRIVATE_FEED_SECRET with spaces'"

    result = CodexWrapper.Result.from_cmd({stdout, 1})

    assert {{:error, {:command_failed, 1}}, ^result} =
             ObanCodex.run(%{"prompt" => "fixture only"},
               job: job_meta(agent),
               query_fun: ObanCodex.Testing.respond(result)
             )

    assert [entry] = Custode.Feed.recent_by_event("turn_failed", agent: agent)
    assert entry["detail"] =~ "exit 1: Error: account rejected"
    assert entry["detail"] =~ "[credential-bearing diagnostic omitted]"
    assert entry["category"] == "unknown_harness_error"
    assert entry["retryable"]
    assert_receive {:feed_entry, ^entry}
    refute Jason.encode!(entry) =~ "PRIVATE_FEED_SECRET"
    refute File.read!(path) =~ "PRIVATE_FEED_SECRET"
    refute File.read!(path) =~ "startup metadata"
  end

  test "Claude result errors stay failures for integer and float costs" do
    workspace = tmp_workspace!()
    agents = [uid("result-zero"), uid("result-float")]

    put_env!(:routines, [
      %{id: Enum.at(agents, 0), cron: "@hourly", workspace: workspace, prompt: "sweep"},
      %{id: Enum.at(agents, 1), cron: "@hourly", workspace: workspace, prompt: "sweep"}
    ])

    assert observer_attached?()

    for {agent, cost} <- Enum.zip(agents, [0, 0.001]) do
      result =
        result(
          result: "API Error: 500 Internal server error",
          is_error: true,
          cost_usd: cost
        )

      assert {{:error, :result_error}, ^result} =
               ObanClaude.run(%{"prompt" => "x"},
                 job: job_meta(agent),
                 query_fun: respond(result)
               )

      assert [failure] = Custode.Feed.recent_by_event("turn_failed", agent: agent)
      assert failure["kind"] == "result_error"
      assert failure["category"] == "unknown_harness_error"
      assert failure["retryable"] == true
      assert failure["detail"] == "API Error: 500 Internal server error"

      assert [%{"category" => "unknown_harness_error", "failures" => 1}] =
               Custode.Feed.recent_by_event("beat_backoff", agent: agent)
    end

    assert observer_attached?()
  end

  test "a failed run is stamped with its category and whether a beat can fix it (#527)" do
    id = uid("feed-auth")

    {{:cancel, :auth}, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: job_meta(id),
        query_fun: fail(error(:auth, reason: :not_authenticated))
      )

    assert [%{"category" => "auth_failed", "retryable" => false}] = Custode.Feed.for_agent(id)
  end

  defp observer_attached? do
    [:oban_claude, :run, :stop]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == "custode-observer"))
  end

  test "the gated states land with their payloads; pause and resume are recorded" do
    id = start_stub_agent!()

    :processing = Agent.submit_prompt(id, "gated")

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => "prune old notes"})
      )

    {:ok, {:awaiting_permission, %{id: action_id}}} =
      Agent.await(id, :awaiting_permission, 1_000)

    :rejected = Agent.reject_action(id, action_id, "test")

    :processing = Agent.submit_prompt(id, "curious")

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "ask_user", "question" => "which one?"})
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)

    :ok = Agent.emergency_pause(id)
    {:ok, :paused} = Agent.await(id, :paused, 1_000)
    :resumed = Agent.resume_agent(id)

    events =
      Custode.Feed.for_agent(id) |> Enum.map(&{&1["event"], &1["action"] || &1["question"]})

    assert {"needs_approval", "prune old notes"} in events
    assert {"needs_input", "which one?"} in events
    assert {"paused", nil} in events
    assert {"resumed", nil} in events
  end

  test "the jsonl MIRROR rotates on size; the db keeps everything", %{path: path} do
    put_env!(:feed_max_bytes, 10)
    agent = uid("rotor")

    Custode.Feed.record(%{event: "first", agent: agent})
    Custode.Feed.record(%{event: "second", agent: agent})

    assert [%{"event" => "first"}] =
             (path <> ".1")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    # rotation is a mirror concern only: the table retains both entries
    assert ["first", "second"] = Custode.Feed.for_agent(agent) |> Enum.map(& &1["event"])
  end

  test "a nil mirror path disables the file without touching the record" do
    put_env!(:feed_path, nil)
    agent = uid("nomirror")

    Custode.Feed.record(%{event: "quiet", agent: agent})
    assert [%{"event" => "quiet"}] = Custode.Feed.for_agent(agent)
  end

  test "gate cards get resolved-in-place chips when worked (approve/reject/answer)" do
    import ObanClaude.Testing
    id = start_stub_agent!()

    :processing = Agent.submit_prompt(id, "go")

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => "do it"})
      )

    {:ok, {:awaiting_permission, action}} = Agent.await(id, :awaiting_permission, 1_000)
    :processing = Agent.approve_action(id, action.id)
    {:ok, :running} = Agent.await(id, :running, 1_000)

    assert [card] =
             Custode.Feed.for_agent(id) |> Enum.filter(&(&1["event"] == "needs_approval"))

    assert card["resolved"] == "approved"
    assert is_binary(card["resolved_at"])

    # the continuation asks a question; answering marks THAT card, the
    # already-resolved one stays untouched
    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "ask_user", "question" => "which?"})
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)
    :ok = Agent.cast_prompt(id, "that one")
    {:ok, :running} = Agent.await(id, :running, 1_000)

    # the answer arrived by cast, so the card is marked resolved by the
    # transition handler after :running is already visible (#257)
    eventually(fn ->
      assert [question] =
               Custode.Feed.for_agent(id) |> Enum.filter(&(&1["event"] == "needs_input"))

      assert question["resolved"] == "answered"
    end)
  end

  test "last_message/2 hides resolved gate events, shows live ones" do
    Custode.Feed.record(%{event: "turn", agent: "lm", summary: "did work"})
    Custode.Feed.record(%{event: "needs_approval", agent: "lm", action: "old gate"})

    # gate resolved: the stale alert must not masquerade as current state
    assert %{"summary" => "did work"} = Custode.Feed.last_message("lm", false)
    # gate still open: the alert IS the last message
    assert %{"action" => "old gate"} = Custode.Feed.last_message("lm", true)
  end

  test "queries bound and order per agent, newest last" do
    for n <- 1..5 do
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-c"),
          query_fun: respond(result(result: "r#{n}", cost_usd: 0.0))
        )
    end

    tail = Custode.Feed.for_agent("feed-c", 2)
    assert length(tail) == 2
    assert Enum.map(tail, & &1["summary"]) == ["r4", "r5"]
  end

  test "import_jsonl!/1 backfills a legacy feed once, timestamps preserved" do
    legacy = Path.join(System.tmp_dir!(), uid("legacy") <> ".jsonl")
    agent = uid("hist")

    File.write!(legacy, """
    {"at":"2026-07-20T10:00:00.000000Z","agent":"#{agent}","event":"turn","summary":"old glory"}
    """)

    on_exit(fn -> File.rm(legacy) end)

    # the import only runs against an empty table (the guard); clear it
    Custode.Repo.query!("DELETE FROM feed_entries")

    assert {:ok, 1} = Custode.Feed.import_jsonl!(legacy)

    assert [%{"summary" => "old glory", "at" => "2026-07-20" <> _rest}] =
             Custode.Feed.for_agent(agent)

    # a second import refuses: the table is no longer empty
    assert_raise MatchError, fn -> Custode.Feed.import_jsonl!(legacy) end
  end

  # `recent_by_event/2` resolves workflow proposals and parked runs for every
  # attention read, and `for_agent/2` backs the console -- so both run on every
  # page render and every PubSub refresh, against a table that grows by a few
  # thousand rows a day from sensors alone (#480). A migration that drops
  # either index turns those reads into full scans, which no behavioural test
  # would notice; this one names the index the planner must pick.
  for {read, where, index} <- [
        {"recent_by_event/2", "WHERE event = 'turn'", "feed_entries_event_id_index"},
        {"for_agent/2", "WHERE agent = 'a'", "feed_entries_agent_id_index"}
      ] do
    test "the hot feed read behind #{read} is index-backed, not a table scan" do
      %{rows: rows} =
        Custode.Repo.query!(
          "EXPLAIN QUERY PLAN SELECT id, entry FROM feed_entries " <>
            unquote(where) <> " ORDER BY id DESC LIMIT 10"
        )

      plan = Enum.map_join(rows, " ", &List.last/1)

      assert plan =~ "SEARCH feed_entries USING",
             "expected an indexed search, got: #{plan}"

      assert plan =~ unquote(index), "expected #{unquote(index)}, got: #{plan}"
    end
  end
end
