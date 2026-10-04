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

  alias Custode.Gates.Grant

  @doc false
  def reply(frame, data), do: {:reply, Snodo.Result.text(JSON.encode!(data)), frame}

  @doc false
  def fail(frame, message), do: {:reply, Snodo.Result.error(message), frame}

  @doc """
  Who is deciding a gate and from which surface, for the gate row (#448).
  """
  def decided(frame) do
    by =
      case Custode.MCP.caller(frame) do
        %{kind: :operator} -> "operator"
        %{id: id} -> id
      end

    [by: by, via: Custode.MCP.origin_transport(frame)]
  end

  @doc false
  def actor_opts(frame) do
    [actor: Custode.MCP.caller(frame), via: Custode.MCP.origin_transport(frame)]
  end

  @doc """
  Gate target authorization uses the same parent relationship as every other
  delegated-agent operation.
  """
  def check_gate_target(frame, target_agent_id),
    do: check_delegated_target(frame, target_agent_id, :manage)

  @doc """
  Authorize a delegated-agent target. Operators may override. A routine may
  create a new temporary identity and may manage only a durable spawn record
  whose parent is that routine. Temporary agents may not delegate.
  """
  def check_delegated_target(frame, target_agent_id, action) when action in [:start, :manage] do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} ->
        :ok

      %{kind: :sub_agent, id: caller_id} ->
        {:error, "identity: temporary agent #{caller_id} may not delegate or control agents"}

      %{kind: :routine, id: caller_id} ->
        check_routine_child(caller_id, target_agent_id, action)
    end
  end

  defp check_routine_child(caller_id, target_agent_id, action) do
    cond do
      Custode.Routine.get(target_agent_id) ->
        {:error,
         "identity: routine #{caller_id} may not control routine #{target_agent_id} -- " <>
           "agents operate the machine; humans judge the work"}

      child = Custode.SubAgents.get(target_agent_id) ->
        if child.parent == caller_id,
          do: :ok,
          else: {:error, "identity: #{target_agent_id} belongs to parent #{child.parent}"}

      action == :start ->
        :ok

      true ->
        {:error, "identity: #{target_agent_id} is not a recorded child of routine #{caller_id}"}
    end
  end

  @doc """
  Notebook/memory self-scope (#2, #488): writes are self-only, as are
  journal reads (#572). Other notebook and memory reads remain open.

  A record (journal, todos, memories, panel, drafts) is written only by the
  agent it belongs to, or by the operator. That holds for every kind of agent
  caller: this used to refuse only a `:routine` naming another id, so a
  sub-agent, the least trusted caller in the tree (design/000), could write
  under its parent's id or a sibling routine's.

  Reads (`todo_list`, ordinary `inbox_list` notes, `recall`) are deliberately
  NOT scoped: an agent may read a sibling's todos, ordinary inbox notes and
  memories by id. Peer notes retain participant scope. Transparency is
  a feature, and agents knowing about each other is what the mesh (#461)
  builds on. To tell another agent something, drop a note in its inbox.
  """
  def check_self(frame, target_id, action \\ :write) when action in [:read, :write] do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} ->
        :ok

      %{id: ^target_id} ->
        :ok

      %{id: caller_id} ->
        hint = if action == :write, do: "; drop a note in its inbox instead", else: ""
        {:error, "identity: #{caller_id} may not #{action} #{target_id}'s records" <> hint}
    end
  end

  @doc """
  The id a self-scoped tool acts on (#483): an explicit `routine_id`, then an
  explicit `agent_id`, then the CALLER's own id when the caller is an agent.

  The `claude` CLI defers MCP tool schemas, so an agent's first call to a
  tool is a guess at its parameter names. The memory tools said `agent_id`,
  the notebook tools said `routine_id`, and an agent that had learned one
  guessed it for the other. The bearer token already says who is calling, so
  the id is optional and either name works. An operator has no records of its
  own: with no id given the answer is `nil`, and the tool asks whose.

  This only RESOLVES the id. `check_self/2` is still what authorizes it, so a
  routine naming a sibling is refused exactly as before.
  """
  @spec self_id(map(), Custode.MCP.CallContext.t()) :: String.t() | nil
  def self_id(params, frame) do
    present(params[:routine_id]) || present(params[:agent_id]) || caller_agent_id(frame)
  end

  @doc """
  `self_id/2` for a `with` chain: `{:ok, id}`, or the tool error to `fail/2`
  with when nobody can tell whose records the call is about (#483).
  """
  @spec fetch_self(map(), Custode.MCP.CallContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_self(params, frame) do
    case self_id(params, frame) do
      nil ->
        {:error,
         "whose records? This call carries no agent identity, so the server cannot " <>
           "default the id. Pass `routine_id` (or its alias `agent_id`)."}

      id ->
        {:ok, id}
    end
  end

  @doc """
  A content field the schema no longer requires, enforced here instead (#483):
  `{:ok, value}`, or `{:error, message}` naming the field, what it means, and
  how to see the rest of the schema.

  The MCP runtime validates the schema BEFORE `execute/2`, and a missing required field
  there is a JSON-RPC protocol error whose detail sits in `error.data`. The
  CLI shows the model only the message, which is the two words "Invalid
  params". An agent that sent `text` and then `entry` for `journal_append`'s
  `body` never learned the name and its sweep went unjournaled. A TOOL error
  (`isError: true`) is text the model does read, so the check moves to where
  it can answer.
  """
  @spec need(map(), atom(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def need(params, key, meaning) do
    case present(params[key]) do
      nil ->
        {:error,
         "missing `#{key}`: #{meaning}. Load this tool's schema with ToolSearch " <>
           "before calling it again."}

      value ->
        {:ok, value}
    end
  end

  @doc """
  The schema description of an identity parameter's second name (#483).
  Argument normalization drops a key the schema does not declare, so an alias the schema left
  out would never reach `self_id/2`: both names are declared, one as this.
  """
  @spec alias_for(String.t()) :: String.t()
  def alias_for(documented) do
    "alias for #{documented}; either works, and both may be omitted: " <>
      "the server knows who is calling"
  end

  # A blank string is as absent as nil: a model guessing at parameters sends
  # "" for a field it has no value for.
  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(value), do: value

  @doc """
  Whether the caller's write `verb` is inside its approved action (#451):
  `:ok`, or `{:error, message}` when `Custode.Gates.Grant` is enforcing. The
  check is on the CALLER, which only this layer knows: the repository process
  knows the repo's owning routine, and a reviewer writes to repos it does not
  own.
  """
  def check_grant(frame, verb), do: Grant.check(caller_agent_id(frame), verb)

  @doc "Run `write` if `check_grant/2` allows `verb`; its refusal is returned in `write`'s error shape."
  def granted(frame, verb, write) when is_function(write, 0) do
    with :ok <- check_grant(frame, verb), do: write.()
  end

  defp caller_agent_id(frame) do
    case Custode.MCP.caller(frame) do
      %{kind: kind, id: id} when kind in [:routine, :sub_agent] -> id
      _operator -> nil
    end
  end
end

defmodule Custode.MCP.Tools.ListRoutines do
  @moduledoc "List the configured routines and each one's live agent status."
  use Custode.MCP.Tool, name: "list_routines"

  import Custode.MCP.Tools

  input_schema(%{"properties" => %{}, "type" => "object"})

  @impl true
  def execute(_params, frame) do
    routines =
      for routine <- Custode.Routine.all() do
        {:ok, status} = Custode.Agents.status(routine.id)

        %{
          id: routine.id,
          provider: routine.provider,
          cron: routine.cron,
          repo: routine.repo,
          tags: routine.tags,
          workspace: Path.expand(routine.workspace),
          working_dir: Path.expand(routine.working_dir),
          status: inspect(status)
        }
      end

    reply(frame, %{routines: routines})
  end
end

defmodule Custode.MCP.Tools.AgentStatus do
  @moduledoc "An agent's lifecycle status, plus turn count / spend / session when running."
  use Custode.MCP.Tool, name: "agent_status"

  import Custode.MCP.Tools

  input_schema(%{
    "properties" => %{
      "agent_id" => %{"description" => "the agent to inspect", "type" => "string"}
    },
    "required" => ["agent_id"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id}, frame) do
    case check_delegated_target(frame, agent_id, :manage) do
      :ok -> status(agent_id, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp status(agent_id, frame) do
    execution = Custode.ExecutionFacts.read(agent_id)

    case Custode.Agents.status(agent_id) do
      {:ok, :offline} ->
        reply(
          frame,
          Map.merge(
            %{
              agent_id: agent_id,
              state: "offline",
              pending_wake: Custode.InboxWakes.read_model(agent_id),
              conversation: Custode.ConversationArcs.read_model(agent_id)
            },
            config_read_model(agent_id, execution)
          )
        )

      {:ok, status} ->
        case Custode.Agents.info(agent_id) do
          {:ok, info} ->
            reply(
              frame,
              Map.merge(
                %{
                  agent_id: agent_id,
                  state: to_string(Custode.MCP.state_of(status)),
                  detail: inspect(status),
                  turns: info.turns,
                  cost_usd: info.cost_usd,
                  session_id: info.session_id,
                  active_arc_id: info.active_arc_id,
                  continuation: info.continuation,
                  pending_wake: Custode.InboxWakes.read_model(agent_id),
                  conversation: Custode.ConversationArcs.read_model(agent_id)
                },
                config_read_model(agent_id, execution)
              )
            )

          {:error, reason} ->
            fail(frame, "agent status changed while it was being read: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail(
          frame,
          "agent lifecycle has conflicting live providers: #{inspect(reason)}"
        )
    end
  end

  defp config_read_model(agent_id, execution) do
    {config_state, transition} =
      case Custode.AgentHandoff.status(agent_id) do
        :ready ->
          {"ready", nil}

        {:pending, pending} ->
          {"transitioning",
           %{
             provider: to_string(pending.provider),
             phase: to_string(pending.phase),
             preserve_pause: pending.preserve_pause?
           }}
      end

    %{
      configured_provider: value(execution.desired, :provider),
      execution_provider: value(execution.applied, :provider),
      desired_config_revision: value(execution.desired, :config_revision),
      applied_config_revision: value(execution.applied, :config_revision),
      config_state: config_state,
      config_transition: transition,
      execution: Map.drop(execution, [:live_error])
    }
  end

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))
end

defmodule Custode.MCP.Tools.StartAgent do
  @moduledoc """
  Start a sub-agent working in a workspace directory. The caller becomes its
  operator: prompt it with prompt_agent, wait with await_agent, and handle its
  ask_user / request_permission gates. Sub-agents get no delegation tools.
  """
  use Custode.MCP.Tool, name: "start_agent"

  import Custode.MCP.Tools

  input_schema(%{
    "properties" => %{
      "agent_id" => %{"description" => "unique id for the sub-agent", "type" => "string"},
      "model" => %{
        "description" => "claude model (defaults to the configured default)",
        "type" => "string"
      },
      "system_prompt" => %{
        "description" => "role instructions (a sensible default applies)",
        "type" => "string"
      },
      "workspace" => %{
        "description" => "absolute path of the directory the sub-agent works in (must exist)",
        "type" => "string"
      }
    },
    "required" => ["agent_id", "workspace"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id, workspace: workspace} = params, frame) do
    workspace = Path.expand(workspace)

    with :ok <- check_delegated_target(frame, agent_id, :start),
         true <- File.dir?(workspace) do
      mcp_config_path = Custode.MCP.write_sub_agent_config!(agent_id)

      config = [
        args:
          Custode.Routine.sub_agent_args(
            workspace,
            params |> Map.put(:mcp_config_path, mcp_config_path) |> Map.put(:agent_id, agent_id)
          ),
        approved_args: %{"permission_mode" => "bypass_permissions"},
        job_timeout: 240_000
      ]

      case Custode.Agents.start_agent(agent_id, config) do
        {:ok, _pid} ->
          # the row is the sub-agent's spec (#5): after a restart the parent
          # gets an orphan notice with a revival handle instead of silence
          Custode.SubAgents.record_spawn!(agent_id, Custode.MCP.caller(frame).id, %{
            workspace: workspace,
            system_prompt: params[:system_prompt],
            model: params[:model]
          })

          reply(frame, %{agent_id: agent_id, state: "idle", workspace: workspace})

        {:error, reason} ->
          fail(frame, "start failed: #{inspect(reason)}")
      end
    else
      {:error, message} -> fail(frame, message)
      false -> fail(frame, "workspace is not an existing directory: #{workspace}")
    end
  end
end

defmodule Custode.MCP.Tools.PromptAgent do
  @moduledoc """
  Send a prompt to an agent (fire-and-forget). If the agent is waiting_for_user,
  this is the answer to its pending question; if it is busy, the prompt queues.
  Follow with await_agent to see the outcome.
  """
  use Custode.MCP.Tool, name: "prompt_agent"

  import Custode.MCP.Tools

  alias Custode.{AgentHandoff, Agents, OperatorMessages}
  alias Custode.Operator.Actions

  input_schema(%{
    "properties" => %{
      "agent_id" => %{"type" => "string"},
      "idempotency_key" => %{
        "description" => "deduplicate this caller's delivery to this agent",
        "type" => "string"
      },
      "prompt" => %{"type" => "string"}
    },
    "required" => ["agent_id", "prompt"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id, prompt: prompt} = params, frame) do
    case check_delegated_target(frame, agent_id, :manage) do
      :ok -> prompt(agent_id, prompt, params, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp prompt(agent_id, prompt, params, frame) do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} -> operator_prompt(agent_id, prompt, params, frame)
      _routine -> delegated_prompt(agent_id, prompt, params, frame)
    end
  end

  # The operator can reach an agent in any state (#472): a paused one is
  # resumed first and an offline routine is started with the prompt. `how`
  # says which, because "delivered" used to be reported for a prompt the
  # engine had dropped. The prompt lands in the activity too (#187).
  defp operator_prompt(agent_id, prompt, params, frame) do
    opts =
      decided(frame) ++
        [
          actor: Custode.MCP.caller(frame),
          idempotency_key: params[:idempotency_key]
        ]

    case Actions.message_with_receipt(agent_id, prompt, opts) do
      {:ok, message, disposition} -> reply_message(message, disposition, frame)
      {:error, {:refused, message, _reason}} -> reply_message(message, :created, frame)
      {:error, reason} -> fail(frame, "prompt failed: #{inspect(reason)}")
    end
  end

  # An agent prompting its own sub-agent is delegation: it stays out of the
  # activity, and it keeps the direct cast. A sub-agent has no routine to
  # start, and a parent must not resume what the operator paused.
  defp delegated_prompt(agent_id, prompt, params, frame) do
    opts = [
      actor: Custode.MCP.caller(frame),
      via: Custode.MCP.origin_transport(frame),
      idempotency_key: params[:idempotency_key]
    ]

    case OperatorMessages.submit(agent_id, prompt, opts, fn message ->
           delegated_delivery(agent_id, prompt, message, frame)
         end) do
      {:ok, message, disposition} -> reply_message(message, disposition, frame)
      {:error, {:refused, message, _reason}} -> reply_message(message, :created, frame)
      {:error, reason} -> fail(frame, "prompt failed: #{inspect(reason)}")
    end
  end

  defp delegated_delivery(agent_id, prompt, message, frame) do
    # Claim before waiting on the handoff coordinator. A configuration reload
    # may already own that boundary, and its generic durable-work recovery
    # must not replay this delegated row before authorization is rechecked.
    case OperatorMessages.claim_delivery(message) do
      {:ok, claimed} ->
        result =
          AgentHandoff.admit(agent_id, fn ->
            admit_delegated(agent_id, prompt, claimed, frame)
          end)

        settle_delegated_admission(claimed, result)

      {:error, :not_queued} ->
        resolve_delegated_claim_miss(message.message_id)
    end
  end

  defp admit_delegated(agent_id, prompt, claimed, frame) do
    with :ok <- check_delegated_target(frame, agent_id, :manage),
         {:ok, provider} <- delegated_provider(agent_id),
         {:ok, state} <- delegated_state(agent_id, provider),
         :ok <- delegated_ready(state) do
      case safe_delegated_cast(agent_id, provider, prompt, claimed.provider_correlation_id) do
        :ok -> record_delegated_admission(claimed, provider)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp delegated_provider(agent_id) do
    case Agents.live_provider(agent_id) do
      {:ok, provider} -> {:ok, provider}
      :offline -> {:error, :agent_not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delegated_state(agent_id, provider) do
    {:ok, status} = Agents.status(agent_id, provider)
    {:ok, Custode.state_of(status)}
  end

  defp delegated_ready(:paused), do: {:error, :agent_paused}
  defp delegated_ready(:offline), do: {:error, :agent_not_running}
  defp delegated_ready(_state), do: :ok

  defp safe_delegated_cast(agent_id, provider, prompt, correlation_id) do
    Agents.cast_prompt(agent_id, provider, prompt, correlation_id: correlation_id)
  rescue
    exception -> {:error, {:cast_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:cast_throw, kind, reason}}
  end

  defp record_delegated_admission(claimed, provider) do
    case OperatorMessages.record_delivery(claimed, :delivered, provider) do
      :ok -> {:admitted, :delivered}
      # The cast was accepted, so releasing the claim could submit it twice.
      # Durable provider-job reconciliation repairs this retained claim.
      {:error, _reason} -> {:admitted, :delivered}
    end
  end

  defp settle_delegated_admission(_claimed, {:admitted, _how} = admitted), do: admitted

  defp settle_delegated_admission(claimed, {:deferred, reason}),
    do: release_delegated_claim(claimed, {:error, {:config_transition, reason}})

  defp settle_delegated_admission(claimed, {:error, _reason} = error),
    do: release_delegated_claim(claimed, error)

  defp settle_delegated_admission(claimed, other),
    do: release_delegated_claim(claimed, {:error, {:unexpected_admission_reply, other}})

  defp release_delegated_claim(claimed, result) do
    case OperatorMessages.release_delivery(claimed) do
      :ok -> result
      {:error, reason} -> {:error, {:release_delivery, reason}}
    end
  end

  defp resolve_delegated_claim_miss(message_id) do
    case OperatorMessages.get(message_id) do
      nil -> {:error, :message_not_found}
      %{delivery: "queued"} -> {:error, :delivery_claim_raced}
      %{delivery: "admitting"} -> {:admitted, :already_admitting}
      %{} -> {:admitted, :already_admitted}
    end
  end

  defp reply_message(message, disposition, frame) do
    payload =
      message
      |> OperatorMessages.public()
      |> Map.put(:agent_id, message.target_agent_id)
      |> Map.put(:delivered, message.status != "refused")
      |> Map.put(:how, message.delivery)
      |> Map.put(:duplicate, disposition == :duplicate)

    reply(frame, payload)
  end
end

defmodule Custode.MCP.Tools.AwaitAgent do
  @moduledoc """
  Block until the agent settles (idle, or blocked on a question/approval),
  then return where it landed plus its latest result. On timeout, returns the
  current state instead of failing.
  """
  use Custode.MCP.Tool, name: "await_agent"

  import Custode.MCP.Tools

  alias Custode.OperatorMessages

  @settled [:idle, :awaiting_permission, :waiting_for_user, :paused, :offline]

  input_schema(%{
    "properties" => %{
      "agent_id" => %{"type" => "string"},
      "message_id" => %{
        "description" =>
          "exact prompt_agent message to await; omit for legacy agent-level waiting",
        "type" => "string"
      },
      "timeout_ms" => %{
        "description" => "max wait, default 60000, capped at 180000",
        "type" => "integer"
      }
    },
    "required" => ["agent_id"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    case check_delegated_target(frame, agent_id, :manage) do
      :ok -> await(agent_id, params, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp await(agent_id, params, frame) do
    case params[:message_id] do
      message_id when is_binary(message_id) -> await_message(agent_id, message_id, params, frame)
      _omitted -> await_agent(agent_id, params, frame)
    end
  end

  defp await_message(agent_id, message_id, params, frame) do
    timeout = params |> Map.get(:timeout_ms, 60_000) |> max(0) |> min(180_000)

    with %{} = message <- OperatorMessages.get(message_id),
         true <- message.target_agent_id == agent_id,
         true <- OperatorMessages.visible_to?(message, Custode.MCP.caller(frame)),
         {:ok, settled, timed_out} <- OperatorMessages.await(message_id, timeout) do
      settled
      |> OperatorMessages.public()
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:timed_out, timed_out)
      |> then(&reply(frame, &1))
    else
      nil -> fail(frame, "message not found: #{message_id}")
      false -> fail(frame, "message #{message_id} does not belong to this caller and target")
      {:error, reason} -> fail(frame, "message wait failed: #{inspect(reason)}")
    end
  end

  defp await_agent(agent_id, params, frame) do
    timeout = params |> Map.get(:timeout_ms, 60_000) |> min(180_000)

    {timed_out, status} =
      case Custode.Agents.await(agent_id, @settled, timeout) do
        {:ok, status} -> {false, status}
        {:error, :timeout} -> {true, elem(Custode.Agents.status(agent_id), 1)}
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
    with {:ok, history} <- Custode.Agents.history(agent_id),
         {:result, result} <- Enum.reverse(history) |> Enum.find(&match?({:result, _}, &1)) do
      if is_map(result), do: result, else: String.slice(to_string(result), 0, 400)
    else
      _other -> nil
    end
  end
end

defmodule Custode.MCP.Tools.AgentHistory do
  @moduledoc "The agent's event log, oldest first, as printable strings."
  use Custode.MCP.Tool, name: "agent_history"

  import Custode.MCP.Tools

  input_schema(%{
    "properties" => %{
      "agent_id" => %{"type" => "string"},
      "last" => %{"description" => "only the last N entries (default 20)", "type" => "integer"}
    },
    "required" => ["agent_id"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    case check_delegated_target(frame, agent_id, :manage) do
      :ok -> history(agent_id, params, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp history(agent_id, params, frame) do
    case Custode.Agents.history(agent_id) do
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
  use Custode.MCP.Tool, name: "approve_action"

  import Custode.MCP.Tools

  input_schema(%{
    "properties" => %{"action_id" => %{"type" => "string"}, "agent_id" => %{"type" => "string"}},
    "required" => ["action_id", "agent_id"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id, action_id: action_id}, frame) do
    case check_gate_target(frame, agent_id) do
      :ok -> do_approve(agent_id, action_id, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp do_approve(agent_id, action_id, frame) do
    case Custode.approve_action(agent_id, action_id, decided(frame)) do
      :processing ->
        reply(frame, %{agent_id: agent_id, approved: action_id})

      {:already_applied, :approved} ->
        reply(frame, %{agent_id: agent_id, approved: action_id, already_applied: true})

      other ->
        fail(frame, "approve failed: #{inspect(other)}")
    end
  end
end

defmodule Custode.MCP.Tools.RejectAction do
  @moduledoc "Reject the action a sub-agent is blocked on; it returns to idle."
  use Custode.MCP.Tool, name: "reject_action"

  import Custode.MCP.Tools

  input_schema(%{
    "properties" => %{
      "action_id" => %{"type" => "string"},
      "agent_id" => %{"type" => "string"},
      "one_off" => %{
        "description" =>
          "true = this rejection applies to this proposal only; the agent is told not to make it a standing rule",
        "type" => "boolean"
      },
      "reason" => %{"type" => "string"}
    },
    "required" => ["action_id", "agent_id"],
    "type" => "object"
  })

  @impl true
  def execute(%{agent_id: agent_id, action_id: action_id} = params, frame) do
    case check_gate_target(frame, agent_id) do
      :ok -> do_reject(agent_id, action_id, params, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp do_reject(agent_id, action_id, params, frame) do
    reason = Map.get(params, :reason)
    opts = Keyword.put(decided(frame), :standing, Map.get(params, :one_off) != true)

    case Custode.reject_with_note(agent_id, action_id, reason, opts) do
      :rejected ->
        reply(frame, %{agent_id: agent_id, rejected: action_id})

      {:already_applied, :rejected} ->
        reply(frame, %{agent_id: agent_id, rejected: action_id, already_applied: true})

      other ->
        fail(frame, "reject failed: #{inspect(other)}")
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
  use Custode.MCP.Tool, name: "run_job"

  import Custode.MCP.Tools

  alias Custode.MCP.Scope

  input_schema(%{
    "properties" => %{
      "elevated" => %{
        "description" =>
          "run with full permissions (git, gh, shell). Use ONLY for work a human already approved via a request_permission gate; default is edit-only",
        "type" => "boolean"
      },
      "max_budget_usd" => %{
        "description" =>
          "per-run spend cap. Defaults to the shared config default, which is sized for small tasks -- pass your own routine's cap when dispatching implementation work",
        "type" => "number"
      },
      "max_turns" => %{
        "description" =>
          "agentic turn cap for the job. Omitted keeps the default (15). Lowering it is always allowed; raising it needs a shell-class approved action in flight whose text names the cap as max_turns=<N>, and the value must be exactly N, within the configured hard ceiling",
        "type" => "integer"
      },
      "model" => %{
        "description" => "claude model (defaults to the configured default)",
        "type" => "string"
      },
      "prompt" => %{"type" => "string"},
      "report_inbox" => %{
        "description" => "absolute path of the directory the completion note is written to",
        "type" => "string"
      },
      "tag" => %{"description" => "short label for the completion note", "type" => "string"},
      "workspace" => %{
        "description" => "absolute path the job's claude runs in (must exist if given)",
        "type" => "string"
      }
    },
    "required" => ["prompt", "report_inbox"],
    "type" => "object"
  })

  @impl true
  def execute(%{prompt: prompt, report_inbox: report_inbox} = params, frame) do
    with {:ok, max_turns} <- Scope.authorize_job_turns(frame, params[:max_turns]),
         {:ok, paths} <-
           Scope.authorize_job(
             frame,
             params[:workspace],
             report_inbox,
             params[:elevated] == true
           ),
         :ok <- existing_directory(paths.report_inbox, "report_inbox"),
         :ok <- existing_optional_directory(paths.workspace, "workspace") do
      args =
        params
        |> job_args(prompt, paths, max_turns)
        |> Custode.IntegrationCatalog.apply_claude(%{
          agent_id: Custode.MCP.caller(frame).id,
          audience: "one_shot"
        })

      {:ok, job} = enqueue(args)
      reply(frame, %{job_id: job.id, reports_to: paths.report_inbox, max_turns: max_turns})
    else
      {:error, message} -> fail(frame, message)
    end
  end

  # :accept_edits covers file edits only; an elevated job (dispatching
  # human-approved work that needs git/gh) runs bypass_permissions with a
  # suite-length timeout -- otherwise the first `git fetch` dies asking a
  # question nobody can answer non-interactively
  defp job_args(params, prompt, paths, max_turns) do
    [
      prompt: prompt,
      model: params[:model] || Application.fetch_env!(:custode, :model),
      max_turns: max_turns,
      max_budget_usd:
        params[:max_budget_usd] || Application.fetch_env!(:custode, :max_budget_usd),
      timeout: if(params[:elevated], do: 900_000, else: 200_000),
      permission_mode: if(params[:elevated], do: :bypass_permissions, else: :accept_edits),
      # force the job's final turn into the report contract (#120): the model
      # MUST return {status, summary, artifacts, cost_note}, so OneShotJob reads
      # typed fields instead of hoping the prose is shaped right.
      json_schema: report_schema()
    ]
    |> maybe_workspace(paths.workspace)
    |> ObanClaude.Args.new()
    |> Map.put("report_inbox", paths.report_inbox)
    |> Map.put("tag", params[:tag] || "job")
  end

  defp existing_directory(path, label) do
    if File.dir?(path),
      do: :ok,
      else: {:error, "#{label} is not an existing directory: #{path}"}
  end

  defp existing_optional_directory(nil, _label), do: :ok
  defp existing_optional_directory(path, label), do: existing_directory(path, label)

  # The one-shot report contract. Kept lenient on which fields are required
  # (status + summary) so a terse job still validates, but strict on shape so
  # the receiving sweep can consume typed fields.
  defp report_schema do
    Jason.encode!(%{
      type: "object",
      additionalProperties: false,
      required: ["status", "summary"],
      properties: %{
        status: %{
          type: "string",
          description: "\"ok\" on success, or a short failure reason"
        },
        summary: %{type: "string", description: "one-line outcome of the job"},
        artifacts: %{
          type: "array",
          items: %{type: "string"},
          description: "paths, PR/issue numbers, or ids the job produced"
        },
        cost_note: %{type: "string", description: "optional note on cost or budget"}
      }
    })
  end

  defp enqueue(args), do: Oban.insert(Custode.OneShotJob.new(args))

  defp maybe_workspace(args, nil), do: args

  defp maybe_workspace(args, workspace),
    do: Keyword.put(args, :working_dir, Path.expand(workspace))
end
