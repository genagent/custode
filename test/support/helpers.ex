defmodule Custode.TestHelpers do
  @moduledoc """
  Shared test plumbing. The app is running (repo, Oban with NO executing
  queues, agent tree, MCP server), so tests drive real modules; claude can
  never be called because no queue executes and stub agents use an injected
  `:enqueue_fun`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Custode.MCP.Snodo, as: MCPRuntime
  alias Custode.Workflow
  alias Custode.Workflow.Node
  alias Custode.Workflow.Stage

  @doc "A unique id with a prefix."
  def uid(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  # Every work-kernel table, ordered so a row is always deleted before what it
  # references (#419). Three tables were hand-maintained in fifteen different
  # modules before this, no two lists agreed, and the disagreement turned
  # `main` red twice: a module clearing too few passes alone and fails with a
  # foreign-key error only once another module leaves one of the missing rows
  # behind, so which module trips is a function of file ordering.
  #
  # `work_tables_complete_test.exs` derives the same set from the schema and
  # fails if this list falls behind, which is the part that makes adding a
  # table safe.
  @work_tables ~w(
    workflow_node_results
    workflow_runs
    work_events
    work_gates
    workspace_leases
    observations
    attempts
    context_bundles
    artifacts
    role_bindings
    legacy_routine_mission_mappings
    work_items
    mission_targets
    operation_calls
    missions
  )

  @doc "The work-kernel tables, in a safe deletion order."
  def work_tables, do: @work_tables

  @doc """
  Clear every work-kernel table.

  Three columns are nulled first because the schema has cycles that no
  ordering can resolve: `attempts -> context_bundles -> artifacts -> attempts`,
  plus `attempts.caused_by_attempt_id` and `work_items.parent_id` pointing at
  their own tables.
  """
  def truncate_work! do
    Custode.Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Custode.Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Custode.Repo.query!("UPDATE work_items SET parent_id = NULL")

    for table <- @work_tables, do: Custode.Repo.query!("DELETE FROM #{table}")

    :ok
  end

  @doc """
  Clear every source of a needs-you signal that has NO agent behind it, plus
  the per-agent ones that outlive their agent.

  A test that asserts on the WHOLE fleet's attention ("exactly one thing needs
  you") is at the mercy of every other module's leftovers, because the test
  database persists and these live outside any one routine: an open ask
  outlives its agent on purpose (#301), a workflow launch proposal and a run
  parked on its rail are agentless (#447), and the host signal is a
  `:persistent_term` (#443). Each of those arrived with a new leak, found the
  same way: a whole-fleet test passing alone and failing under some seed.

  One list here for the same reason as `truncate_work!/0`: several suites each
  kept their own, no two agreed, and the list that was missing a line was the
  one that failed.
  """
  def clear_attention! do
    for table <- ~w(asks gates gate_reviews disowned_prs workflow_node_results workflow_runs) do
      Custode.Repo.query!("DELETE FROM #{table}")
    end

    Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
    Custode.Repo.query!("DELETE FROM memories WHERE key = 'ci_infrastructure'")
    Custode.Host.reset()
    :ok
  end

  @doc """
  Start an agent whose enqueues land in the calling test's mailbox as
  `{:enqueued, args, meta}`. Stopped on test exit.
  """
  def start_stub_agent!(opts \\ []) do
    id = uid("t")
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} =
      ObanClaude.Agent.start_agent(id, Keyword.merge([enqueue_fun: enqueue_fun], opts))

    on_exit(fn -> ObanClaude.Agent.stop_agent(id) end)
    id
  end

  @doc """
  Complete a captured persisted job, or metadata from a stub enqueue.
  Persisted jobs keep their id so the engine can reject other job callbacks.

  Route through the real worker callback so this fixture preserves the
  engine's correlation contract. Never reconstruct metadata from an agent's
  current state: a queued prompt or replacement agent may already own it.
  """
  def finish_agent_turn(%{id: id, meta: meta}, %ClaudeWrapper.Result{} = result) do
    ObanClaude.Agent.Job.handle_result(
      result,
      %Oban.Job{id: id, meta: meta, attempt: 1, max_attempts: 1}
    )
  end

  def finish_agent_turn(%{"agent_id" => _id} = meta, %ClaudeWrapper.Result{} = result) do
    ObanClaude.Agent.Job.handle_result(result, %Oban.Job{meta: meta, attempt: 1, max_attempts: 1})
  end

  @doc "A tmp workspace directory with an inbox/, removed on test exit."
  def tmp_workspace! do
    dir = Path.join(System.tmp_dir!(), uid("custode-ws"))
    File.mkdir_p!(Path.join(dir, "inbox"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  Leave `Custode.Installation` unprovisioned and point the configured database
  at a temporary directory, so a test can prove a read never creates the id
  file. Returns the path a lazy create would have written. The boot-provisioned
  id and the database config are restored on exit.
  """
  def unprovision_installation! do
    booted = Custode.Installation.fetch()
    dir = Path.join(System.tmp_dir!(), uid("custode-installation"))
    File.mkdir_p!(dir)
    database = Path.join(dir, "custode.db")

    put_env!(
      Custode.Repo,
      :custode |> Application.get_env(Custode.Repo, []) |> Keyword.put(:database, database)
    )

    Custode.Installation.forget()

    on_exit(fn ->
      Custode.Installation.restore(booted)
      File.rm_rf!(dir)
    end)

    database <> ".installation"
  end

  @doc "Point `key` app env at `value` for this test, restoring afterwards."
  def put_env!(key, value) do
    previous = Application.fetch_env(:custode, key)
    Application.put_env(:custode, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:custode, key, old)
        :error -> Application.delete_env(:custode, key)
      end
    end)
  end

  @doc """
  Register a toy workflow in the catalog for this test, removed afterwards.
  Three cheap stages walk the same shape `backlog-sweep` has (a fan-out at the
  end) without rendering its prompts.
  """
  def workflow_fixture!(name) do
    node = fn node_name -> %Node{name: node_name, prompt: "do <%= @repo %>", schema: %{}} end

    workflow =
      Workflow.new!(name, [
        %Stage{name: :mine, nodes: [node.(:spec), node.(:code)]},
        %Stage{name: :merge, nodes: [node.(:merge)]},
        %Stage{name: :check, per_item: true, nodes: [node.(:check)]}
      ])

    extra = Application.get_env(:custode, :extra_workflows, %{})
    put_env!(:extra_workflows, Map.put(extra, workflow.name, workflow))
    workflow
  end

  @doc "Configure one routine targeting `workspace` and return its normalized form."
  def routine_fixture!(workspace, extra \\ %{}) do
    routine =
      Map.merge(
        %{id: uid("routine"), cron: "@daily", workspace: workspace, prompt: "sweep now"},
        extra
      )

    put_env!(:routines, [routine])
    Custode.Routine.default()
  end

  @doc "Decode the JSON payload out of an MCP tool `{:reply, response, frame}`."
  def tool_json({:reply, %Snodo.Result{kind: :text, value: text}, _frame}),
    do: Jason.decode!(text)

  @doc "Extract the error text out of an MCP tool error reply."
  def tool_error({:reply, %Snodo.Result{kind: :error, value: text}, _frame}), do: text

  @doc "Dispatch a protocol request; target authorization remains in shared operations."
  def mcp_dispatch(method, params, frame, server \\ Custode.MCP.Server) do
    path = if server == Custode.MCP.MemoryServer, do: "/mcp/memory", else: "/mcp"
    runtime = MCPRuntime.plug_options()[path].runtime
    runtime = %{runtime | authorization: nil}

    transport = %Snodo.Transport.Context{
      request_headers: %{"mcp-protocol-version" => "2025-06-18"},
      metadata: %{auth: %{identity: Custode.MCP.caller(frame), origin: :mcp}}
    }

    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    case Snodo.Server.dispatch(runtime, request, transport) do
      {:ok, %{"result" => result}} -> {:reply, result, frame}
      {:ok, %{"error" => error}} -> {:error, error, frame}
    end
  end

  @doc """
  Retry `fun` until it stops raising, re-raising the last failure once
  `timeout` passes. Returns whatever `fun` returns.

  For assertions on state another process writes (#257).
  `ObanClaude.Agent.Instance.sync_transition/3` updates the registry BEFORE
  it emits `[:oban_claude, :agent, :transition]`, and
  `ObanClaude.Agent.await/3` polls that registry from the test process --
  so `await` returning proves the state changed, not that the gate row, the
  feed card or the metric a telemetry handler writes exists yet. Whenever
  the transition came from a cast (`finish_agent_turn/2`, `emergency_pause/1`),
  poll for the row itself. Transitions driven by a call
  (`submit_prompt/3`, `approve_action/3`, `reject_action/3`) reply after
  `sync_transition`, so those reads need no retry.
  """
  def eventually(fun, timeout \\ 2_000) do
    do_eventually(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_eventually(fun, deadline) do
    fun.()
  rescue
    exception ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  @doc "All oban_jobs rows for a worker, args/meta decoded."
  def jobs_for(worker) do
    import Ecto.Query, only: [from: 2]

    Custode.Repo.all(
      from(j in "oban_jobs",
        where: j.worker == ^worker,
        order_by: [asc: j.id],
        select: %{id: j.id, queue: j.queue, state: j.state, args: j.args, meta: j.meta}
      )
    )
    |> Enum.map(fn j -> %{j | args: Jason.decode!(j.args), meta: Jason.decode!(j.meta)} end)
  end
end
