defmodule Custode.RunContextObservationTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Custode.{Agents, Repo, RunContextObservation, RunContextReceipts}
  alias RunContextReceipts.Row
  @endpoint CustodeWeb.Endpoint
  @human %{kind: :operator, id: "observation-human"}

  setup do
    Repo.delete_all(Row)
    on_exit(fn -> Repo.delete_all(Row) end)
    :ok
  end

  test "both released engines bind accepted native callbacks to actual adapter telemetry without inference" do
    for provider <- [:oban_claude, :oban_codex] do
      ctx = execution(provider, capture: false)

      query = fn _prompt, _options ->
        {_state, data} = :sys.get_state(ctx.pid)

        emit_observation(
          {ctx.pid, data.current_turn.execution.reference},
          provider,
          "native-handle"
        )

        eventually(fn -> assert observation(ctx)["provider_session_id"] == "native-handle" end)
        {:error, :synthetic_nonpaid_stop}
      end

      module = adapter(provider)
      module.run(ctx.job.args, job: ctx.job, query_fun: query)
      assert {:ok, [receipt]} = RunContextReceipts.list(@human, ctx.id)
      assert receipt["native_observation"]["provider_session_id"] == "native-handle"
      assert receipt["native_observation"]["source"] == source(provider) |> Atom.to_string()
      assert receipt["execution"]["job_id"] == ctx.job.id
      assert receipt["provider_received"] == "unknown"
      assert receipt["model_used"] == "unknown"
      assert receipt["native_hidden_context"] == "unknown"
      assert receipt["tokens"] == nil
    end
  end

  test "first fact and payload survive duplicate, conflict, cleanup and reuse of an agent id" do
    ctx = execution(:oban_claude)
    first_payload = Repo.get!(Row, ctx.receipt["receipt_id"]).payload
    emit_observation(ctx.observer, ctx.provider, "first")
    eventually(fn -> assert observation(ctx)["provider_session_id"] == "first" end)
    first = observation(ctx)
    emit_observation(ctx.observer, ctx.provider, "first")
    emit_observation(ctx.observer, ctx.provider, "conflict")
    assert {:ok, _} = Agents.info(ctx.id, :claude)
    assert observation(ctx) == first

    assert {:error, :conflicting_native_observation} =
             owned_observe(ctx, %{session_id: "conflict"})

    assert observation(ctx) == first
    assert Repo.get!(Row, ctx.receipt["receipt_id"]).payload == first_payload
    assert :ok = Agents.stop_agent(ctx.id, :claude)
    Repo.delete!(ctx.job)
    assert observation(ctx) == first

    {:ok, _pid} = Agents.start_agent(ctx.id, :claude, enqueue_fun: fn _, _ -> {:ok, :queued} end)
    on_exit(fn -> Agents.stop_agent(ctx.id, :claude) end)
    emit_observation(ctx.observer, ctx.provider, "restarted")
    assert observation(ctx) == first

    assert {:ok, view, html} =
             live(build_conn(), "/contexts/#{ctx.id}?receipt=#{ctx.receipt["receipt_id"]}")

    assert has_element?(view, "#run-context-native")
    assert html =~ "first"
    assert html =~ "Context receipt and model use remain unknown"
  end

  test "ordinary processes and missing or hostile exact identities cannot attach" do
    ctx = execution(:oban_claude)

    assert {:error, :unbound_native_observation} =
             RunContextObservation.observe(ctx.provider, meta(ctx))

    for key <- ~w(agent_id agent_generation agent_turn_id arc_id config_revision correlation_id)a do
      assert {:error, :unbound_native_observation} = owned_observe(ctx, %{key => "wrong"})
      assert {:error, :unbound_native_observation} = owned_observe(ctx, %{}, [key])
    end

    for overrides <- [
          %{job_id: ctx.job.id + 1},
          %{job_attempt: 2},
          %{job_snoozed: 1},
          %{execution_state: :not_started},
          %{source: :thread_started},
          %{session_id: ""},
          %{session_id: " "},
          %{session_id: <<255>>},
          %{session_id: String.duplicate("x", 257)}
        ] do
      assert {:error, :unbound_native_observation} = owned_observe(ctx, overrides)
    end

    assert {:error, :unbound_native_observation} = owned_observe(ctx, %{}, [], :oban_codex)
    assert observation(ctx) == nil
  end

  test "terminal, retried, snoozed, wrong worker and changed persisted jobs refuse" do
    ctx = execution(:oban_claude)

    for changes <- [
          [state: "completed"],
          [state: "cancelled"],
          [state: "discarded"],
          [state: "retryable"],
          [state: "available"],
          [attempt: 2],
          [worker: "ObanCodex.Agent.Job"],
          [args: Map.put(ctx.job.args, "prompt", "changed")],
          [meta: Map.put(ctx.job.meta, "snoozed", 1)],
          [meta: Map.put(ctx.job.meta, "unrelated", "changed")]
        ] do
      Repo.update!(Ecto.Changeset.change(ctx.job, changes))
      assert {:error, :unbound_native_observation} = owned_observe(ctx)

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Oban.Job, ctx.job.id),
          state: ctx.job.state,
          attempt: ctx.job.attempt,
          worker: ctx.job.worker,
          args: ctx.job.args,
          meta: ctx.job.meta
        )
      )
    end

    assert observation(ctx) == nil
  end

  test "expired, retired, over-budget, missing and legacy receipts never revive" do
    ctx = execution(:oban_claude)
    row = Repo.get!(Row, ctx.receipt["receipt_id"])

    for changes <- [
          [at: DateTime.add(row.at, -8, :day)],
          [payload: nil],
          [record: Map.put(row.record, "payload_state", "over_budget")],
          [record: Map.delete(row.record, "job_metadata_sha256")]
        ] do
      Repo.update!(Ecto.Changeset.change(row, changes))
      assert {:error, :unbound_native_observation} = owned_observe(ctx)

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Row, row.receipt_id),
          at: row.at,
          payload: row.payload,
          record: row.record
        )
      )
    end

    Repo.delete!(row)
    assert {:error, :unbound_native_observation} = owned_observe(ctx)
    refute Repo.get(Row, row.receipt_id)
  end

  test "accepted callback before capture and after terminal closure is not backfilled" do
    ctx = execution(:oban_codex, capture: false)
    observer = ObanCodex.Agent.Job.session_observer(ctx.job)
    emit_observation(observer, ctx.provider, "too-early")
    assert {:ok, _} = Agents.info(ctx.id, :codex)
    assert {:ok, receipt} = RunContextReceipts.capture(ctx.provider, event(ctx.job))
    ctx = Map.put(ctx, :receipt, receipt)
    assert observation(ctx) == nil
    emit_observation(observer, ctx.provider, "too-early")
    assert {:ok, _} = Agents.info(ctx.id, :codex)
    assert observation(ctx) == nil

    ObanCodex.Agent.Job.handle_result(ObanCodex.Testing.result(session_id: "too-early"), ctx.job)
    assert {:ok, :idle} = Agents.await(ctx.id, :codex, :idle, 1_000)
    emit_observation(observer, ctx.provider, "too-late")
    assert {:ok, _} = Agents.info(ctx.id, :codex)
    assert observation(ctx) == nil
  end

  test "stale retry callback cannot bind the next attempt and scheduled nil correlation is exact" do
    ctx = execution(:oban_claude, correlation_id: nil)
    emit_observation({ctx.pid, make_ref()}, ctx.provider, "wrong-reference")
    assert {:ok, _} = Agents.info(ctx.id, :claude)
    assert observation(ctx) == nil
    assert {:ok, _first} = owned_observe(ctx)
    first = observation(ctx)
    retry = Repo.update!(Ecto.Changeset.change(ctx.job, attempt: 2))
    assert {:ok, next} = RunContextReceipts.capture(ctx.provider, event(retry))
    emit_observation(ctx.observer, ctx.provider, "stale-first")
    assert {:ok, _} = Agents.info(ctx.id, :claude)
    assert observation(%{ctx | receipt: next}) == nil
    assert observation(ctx) == first
  end

  defp execution(provider, options \\ []) do
    id = uid("native-context")
    parent = self()
    agent = if provider == :oban_claude, do: :claude, else: :codex
    job_module = if agent == :claude, do: ObanClaude.Agent.Job, else: ObanCodex.Agent.Job
    revision = uid("config")

    {:ok, pid} =
      Agents.start_agent(id, agent,
        config_revision: revision,
        enqueue_fun: fn args, meta ->
          job = job_module.new(args, meta: meta) |> Oban.insert!()
          send(parent, {:context_job, job})
          {:ok, job}
        end
      )

    on_exit(fn -> Agents.stop_agent(id, agent) end)

    assert :processing =
             Agents.submit_prompt(id, "Frozen context",
               correlation_id: Keyword.get(options, :correlation_id, uid("correlation"))
             )

    assert_receive {:context_job, job}
    job = Repo.update!(Ecto.Changeset.change(job, state: "executing", attempt: 1))

    on_exit({:native_job, job.id}, fn ->
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
    end)

    base = %{id: id, pid: pid, job: job, provider: provider}

    if Keyword.get(options, :capture, true) do
      observer = job_module.session_observer(job)
      assert {:ok, receipt} = RunContextReceipts.capture(provider, event(job))
      Map.merge(base, %{observer: observer, receipt: receipt})
    else
      base
    end
  end

  defp event(job), do: %{args: job.args, job: job}
  defp adapter(:oban_claude), do: ObanClaude
  defp adapter(:oban_codex), do: ObanCodex
  defp source(:oban_claude), do: :system_init
  defp source(:oban_codex), do: :thread_started

  defp meta(ctx) do
    identity =
      Map.new(
        ~w(agent_id agent_generation agent_turn_id arc_id config_revision correlation_id),
        fn key -> {String.to_existing_atom(key), ctx.job.meta[key]} end
      )

    Map.merge(identity, %{
      job_id: ctx.job.id,
      job_attempt: ctx.job.attempt,
      job_snoozed: 0,
      execution_state: :started,
      source: source(ctx.provider),
      session_id: "observed"
    })
  end

  # Hostile host-fixture probes run inside the registered process to exercise
  # the independent durable tuple checks. Ordinary callers cannot do this.
  defp owned_observe(ctx, overrides \\ %{}, dropped \\ [], provider \\ nil) do
    parent = self()
    reference = make_ref()

    :sys.replace_state(ctx.pid, fn state ->
      result =
        RunContextObservation.observe(
          provider || ctx.provider,
          meta(ctx) |> Map.merge(overrides) |> Map.drop(dropped)
        )

      send(parent, {reference, result})
      state
    end)

    assert_receive {^reference, result}
    result
  end

  defp emit_observation({pid, reference}, :oban_claude, id),
    do:
      send(
        pid,
        {reference, %ClaudeWrapper.SessionObservation{session_id: id, source: :system_init}}
      )

  defp emit_observation({pid, reference}, :oban_codex, id),
    do:
      send(
        pid,
        {reference, %CodexWrapper.SessionObservation{session_id: id, source: :thread_started}}
      )

  defp observation(ctx) do
    case RunContextReceipts.list(@human, ctx.id) do
      {:ok, receipts} when not is_map_key(ctx, :receipt) ->
        case receipts do
          [receipt] -> receipt["native_observation"] || %{}
          [] -> %{}
        end

      {:ok, _} ->
        {:ok, receipt} = RunContextReceipts.read(@human, ctx.receipt["receipt_id"])
        receipt["native_observation"]
    end
  end
end
