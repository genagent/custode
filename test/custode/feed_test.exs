defmodule Custode.FeedTest do
  # The feed handlers are attached globally at app boot and the path is read
  # per write, so each test points :feed_path at its own tmp file.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

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

  test "a failed run is stamped with its category and whether a beat can fix it (#527)" do
    id = uid("feed-auth")

    {{:cancel, :auth}, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: job_meta(id),
        query_fun: fail(error(:auth, reason: :not_authenticated))
      )

    assert [%{"category" => "auth_failed", "retryable" => false}] = Custode.Feed.for_agent(id)
  end

  test "the gated states land with their payloads; pause and resume are recorded" do
    id = start_stub_agent!()

    :processing = Agent.submit_prompt(id, "gated")

    :ok =
      Agent.job_finished(
        id,
        {:ok,
         structured_result(%{"directive" => "request_permission", "action" => "prune old notes"})}
      )

    {:ok, {:awaiting_permission, %{id: action_id}}} =
      Agent.await(id, :awaiting_permission, 1_000)

    :rejected = Agent.reject_action(id, action_id, "test")

    :processing = Agent.submit_prompt(id, "curious")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which one?"})}
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

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "do it"})}
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
    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)
    :ok = Agent.cast_prompt(id, "that one")
    {:ok, :running} = Agent.await(id, :running, 1_000)

    # the answer arrived by cast, so the card is marked resolved by the
    # transition handler after :running is already visible (#257)
    question =
      eventually(fn ->
        assert [question] =
                 Custode.Feed.for_agent(id) |> Enum.filter(&(&1["event"] == "needs_input"))

        question
      end)

    assert question["resolved"] == "answered"
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
