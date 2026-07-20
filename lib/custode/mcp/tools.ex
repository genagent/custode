defmodule Custode.MCP.Tools do
  @moduledoc """
  The MCP toolbox agents use to drive sibling agents and jobs. Two tiers:

    * `run_job` -- fire-and-forget one-shot claude job; its result lands as a
      note in a `report_inbox` directory (usually the caller's own inbox), to
      be picked up by a later sweep. The custode-native async return channel.
    * `start_agent` / `prompt_agent` / `await_agent` / `agent_status` /
      `agent_history` / `approve_action` / `reject_action` -- full sub-agents
      with the whole lifecycle, for supervised multi-step work. The calling
      agent is its sub-agents' operator.

  Every tool returns JSON text content. Errors are tool-level errors (the
  calling model sees them and can react).
  """

  alias Anubis.Server.Response

  @doc false
  def reply(frame, data), do: {:reply, Response.json(Response.tool(), data), frame}

  @doc false
  def fail(frame, message), do: {:reply, Response.error(Response.tool(), message), frame}
end

defmodule Custode.MCP.Tools.ListRoutines do
  @moduledoc "List the configured routines and each one's live agent status."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    routines =
      for routine <- Custode.Routine.all() do
        {:ok, status} = ObanClaude.Agent.status(routine.id)

        %{
          id: routine.id,
          cron: routine.cron,
          workspace: Path.expand(routine.workspace),
          status: inspect(status)
        }
      end

    reply(frame, %{routines: routines})
  end
end

defmodule Custode.MCP.Tools.AgentStatus do
  @moduledoc "An agent's lifecycle status, plus turn count / spend / session when running."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "the agent to inspect")
  end

  @impl true
  def execute(%{agent_id: agent_id}, frame) do
    case ObanClaude.Agent.status(agent_id) do
      {:ok, :offline} ->
        reply(frame, %{agent_id: agent_id, state: "offline"})

      {:ok, status} ->
        {:ok, info} = ObanClaude.Agent.info(agent_id)

        reply(frame, %{
          agent_id: agent_id,
          state: to_string(Custode.MCP.state_of(status)),
          detail: inspect(status),
          turns: info.turns,
          cost_usd: info.cost_usd,
          session_id: info.session_id
        })
    end
  end
end

defmodule Custode.MCP.Tools.StartAgent do
  @moduledoc """
  Start a sub-agent working in a workspace directory. The caller becomes its
  operator: prompt it with prompt_agent, wait with await_agent, and handle its
  ask_user / request_permission gates. Sub-agents get no delegation tools.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "unique id for the sub-agent")

    field(:workspace, :string,
      required: true,
      description: "absolute path of the directory the sub-agent works in (must exist)"
    )

    field(:system_prompt, :string, description: "role instructions (a sensible default applies)")
    field(:model, :string, description: "claude model (defaults to the configured default)")
  end

  @impl true
  def execute(%{agent_id: agent_id, workspace: workspace} = params, frame) do
    workspace = Path.expand(workspace)

    if File.dir?(workspace) do
      config = [
        args: Custode.Routine.sub_agent_args(workspace, params),
        approved_args: %{"permission_mode" => "dont_ask"},
        job_timeout: 240_000
      ]

      case ObanClaude.Agent.start_agent(agent_id, config) do
        {:ok, _pid} -> reply(frame, %{agent_id: agent_id, state: "idle", workspace: workspace})
        {:error, reason} -> fail(frame, "start failed: #{inspect(reason)}")
      end
    else
      fail(frame, "workspace is not an existing directory: #{workspace}")
    end
  end
end

defmodule Custode.MCP.Tools.PromptAgent do
  @moduledoc """
  Send a prompt to an agent (fire-and-forget). If the agent is waiting_for_user,
  this is the answer to its pending question; if it is busy, the prompt queues.
  Follow with await_agent to see the outcome.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true)
    field(:prompt, :string, required: true)
  end

  @impl true
  def execute(%{agent_id: agent_id, prompt: prompt}, frame) do
    case ObanClaude.Agent.cast_prompt(agent_id, prompt) do
      :ok -> reply(frame, %{agent_id: agent_id, delivered: true})
      {:error, reason} -> fail(frame, "prompt failed: #{inspect(reason)}")
    end
  end
end

defmodule Custode.MCP.Tools.AwaitAgent do
  @moduledoc """
  Block until the agent settles (idle, or blocked on a question/approval),
  then return where it landed plus its latest result. On timeout, returns the
  current state instead of failing.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @settled [:idle, :awaiting_permission, :waiting_for_user, :paused, :offline]

  schema do
    field(:agent_id, :string, required: true)
    field(:timeout_ms, :integer, description: "max wait, default 60000, capped at 180000")
  end

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    timeout = params |> Map.get(:timeout_ms, 60_000) |> min(180_000)

    {timed_out, status} =
      case ObanClaude.Agent.await(agent_id, @settled, timeout) do
        {:ok, status} -> {false, status}
        {:error, :timeout} -> {true, elem(ObanClaude.Agent.status(agent_id), 1)}
      end

    reply(frame, %{
      agent_id: agent_id,
      state: to_string(Custode.MCP.state_of(status)),
      detail: inspect(status),
      timed_out: timed_out,
      last_result: last_result(agent_id)
    })
  end

  defp last_result(agent_id) do
    with {:ok, history} <- ObanClaude.Agent.history(agent_id),
         {:result, result} <- Enum.reverse(history) |> Enum.find(&match?({:result, _}, &1)) do
      if is_map(result), do: result, else: String.slice(to_string(result), 0, 400)
    else
      _other -> nil
    end
  end
end

defmodule Custode.MCP.Tools.AgentHistory do
  @moduledoc "The agent's event log, oldest first, as printable strings."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true)
    field(:last, :integer, description: "only the last N entries (default 20)")
  end

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    case ObanClaude.Agent.history(agent_id) do
      {:ok, history} ->
        n = Map.get(params, :last, 20)
        entries = history |> Enum.take(-n) |> Enum.map(&inspect(&1, printable_limit: 200))
        reply(frame, %{agent_id: agent_id, entries: entries})

      {:error, reason} ->
        fail(frame, inspect(reason))
    end
  end
end

defmodule Custode.MCP.Tools.ApproveAction do
  @moduledoc "Approve the action a sub-agent is blocked on (get the action id from await_agent/agent_status)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true)
    field(:action_id, :string, required: true)
  end

  @impl true
  def execute(%{agent_id: agent_id, action_id: action_id}, frame) do
    case ObanClaude.Agent.approve_action(agent_id, action_id) do
      :processing -> reply(frame, %{agent_id: agent_id, approved: action_id})
      other -> fail(frame, "approve failed: #{inspect(other)}")
    end
  end
end

defmodule Custode.MCP.Tools.RejectAction do
  @moduledoc "Reject the action a sub-agent is blocked on; it returns to idle."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true)
    field(:action_id, :string, required: true)
    field(:reason, :string)
  end

  @impl true
  def execute(%{agent_id: agent_id, action_id: action_id} = params, frame) do
    case ObanClaude.Agent.reject_action(agent_id, action_id, Map.get(params, :reason, "denied")) do
      :rejected -> reply(frame, %{agent_id: agent_id, rejected: action_id})
      other -> fail(frame, "reject failed: #{inspect(other)}")
    end
  end
end

defmodule Custode.MCP.Tools.RunJob do
  @moduledoc """
  Fire-and-forget one-shot claude job. Returns immediately with the job id;
  when the job finishes, its result is written as a note into report_inbox
  (typically the caller's own inbox/ directory), where a later sweep picks it
  up. Prefer this over start_agent for bounded single tasks.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:prompt, :string, required: true)

    field(:workspace, :string,
      description: "absolute path the job's claude runs in (must exist if given)"
    )

    field(:report_inbox, :string,
      required: true,
      description: "absolute path of the directory the completion note is written to"
    )

    field(:model, :string, description: "claude model (defaults to the configured default)")
    field(:tag, :string, description: "short label for the completion note")
  end

  @impl true
  def execute(%{prompt: prompt, report_inbox: report_inbox} = params, frame) do
    cond do
      not File.dir?(Path.expand(report_inbox)) ->
        fail(frame, "report_inbox is not an existing directory: #{report_inbox}")

      params[:workspace] && not File.dir?(Path.expand(params[:workspace])) ->
        fail(frame, "workspace is not an existing directory: #{params[:workspace]}")

      true ->
        args =
          [
            prompt: prompt,
            model: params[:model] || Application.fetch_env!(:custode, :model),
            max_turns: 15,
            max_budget_usd: Application.fetch_env!(:custode, :max_budget_usd),
            timeout: 200_000,
            permission_mode: :accept_edits
          ]
          |> maybe_workspace(params[:workspace])
          |> ObanClaude.Args.new()
          |> Map.put("report_inbox", Path.expand(report_inbox))
          |> Map.put("tag", params[:tag] || "job")

        {:ok, job} = Oban.insert(Custode.OneShotJob.new(args))
        reply(frame, %{job_id: job.id, reports_to: Path.expand(report_inbox)})
    end
  end

  defp maybe_workspace(args, nil), do: args

  defp maybe_workspace(args, workspace),
    do: Keyword.put(args, :working_dir, Path.expand(workspace))
end
