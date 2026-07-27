defmodule Custode.TestHelpers do
  @moduledoc """
  Shared test plumbing. The app is running (repo, Oban with NO executing
  queues, agent tree, MCP server), so tests drive real modules; claude can
  never be called because no queue executes and stub agents use an injected
  `:enqueue_fun`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Anubis.Server.Response
  alias Custode.Workflow
  alias Custode.Workflow.Node
  alias Custode.Workflow.Stage

  @doc "A unique id with a prefix."
  def uid(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

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

  @doc "A tmp workspace directory with an inbox/, removed on test exit."
  def tmp_workspace! do
    dir = Path.join(System.tmp_dir!(), uid("custode-ws"))
    File.mkdir_p!(Path.join(dir, "inbox"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
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
  def tool_json({:reply, response, _frame}) do
    %{"content" => [%{"text" => text} | _rest], "isError" => false} =
      Response.to_protocol(response)

    Jason.decode!(text)
  end

  @doc "Extract the error text out of an MCP tool error reply."
  def tool_error({:reply, response, _frame}) do
    %{"content" => [%{"text" => text} | _rest], "isError" => true} =
      Response.to_protocol(response)

    text
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
  the transition came from a cast (`job_finished/2`, `emergency_pause/1`),
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
