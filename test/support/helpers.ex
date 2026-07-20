defmodule Custode.TestHelpers do
  @moduledoc """
  Shared test plumbing. The app is running (repo, Oban with NO executing
  queues, agent tree, MCP server), so tests drive real modules; claude can
  never be called because no queue executes and stub agents use an injected
  `:enqueue_fun`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

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
      Anubis.Server.Response.to_protocol(response)

    Jason.decode!(text)
  end

  @doc "Extract the error text out of an MCP tool error reply."
  def tool_error({:reply, response, _frame}) do
    %{"content" => [%{"text" => text} | _rest], "isError" => true} =
      Anubis.Server.Response.to_protocol(response)

    text
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
