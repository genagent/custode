defmodule Custode.MCP.PermissionTools do
  @moduledoc """
  Claude permission-prompt decisions for Custode MCP tools.

  A request carries the tool Claude wants to call and its original input. The
  authenticated MCP connection, never a request field, identifies the routine.
  The broker permits only tools in that routine's durable execution contract
  that `Custode.MCP.ToolPolicy` classifies as read-only.
  """

  @server_prefix "mcp__custode__"
  @broker_tool "permission_decide"
  @audit_tool_limit 200

  alias Custode.MCP.{Capabilities, ToolPolicy}

  @doc false
  def decide(params, frame) do
    input = value(params, :input)
    requested_tool = value(params, :tool_name)

    with {:ok, routine_id} <- authenticated_routine(frame),
         :ok <- valid_request(requested_tool, input),
         {:ok, snapshot} <- authorization_snapshot(routine_id) do
      decide_with_snapshot(routine_id, requested_tool, input, snapshot)
    else
      {:error, reason} ->
        routine_id = routine_id(frame)

        {:deny, denial_message(reason), audit(routine_id, requested_tool, :deny, reason, nil)}
    end
  end

  defp decide_with_snapshot(routine_id, requested_tool, input, snapshot) do
    with {:ok, tool} <- local_tool(requested_tool),
         :ok <- not_recursive(tool),
         {:ok, category} <- known_tool(tool),
         :ok <- in_capability_set(snapshot, tool),
         :ok <- read_only(category) do
      {:allow, input, audit(routine_id, requested_tool, :allow, :read_only, snapshot)}
    else
      {:error, reason} ->
        {:deny, denial_message(reason),
         audit(routine_id, requested_tool, :deny, reason, snapshot)}
    end
  end

  defp authenticated_routine(%{
         assigns: %{custode_identity: %{kind: :routine, id: id}}
       })
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp authenticated_routine(_frame), do: {:error, :authenticated_routine_required}

  defp valid_request(tool_name, input)
       when is_binary(tool_name) and tool_name != "" and is_map(input),
       do: :ok

  defp valid_request(_tool_name, _input), do: {:error, :malformed_request}

  defp authorization_snapshot(routine_id) do
    case Custode.AgentHandoff.authorization_routine(routine_id) do
      {:ok, %{role: role} = snapshot} when is_atom(role) ->
        {:ok, snapshot}

      _unavailable ->
        {:error, :authorization_unavailable}
    end
  end

  defp local_tool(@server_prefix <> tool) when tool != "", do: {:ok, tool}
  defp local_tool(_tool), do: {:error, :outside_custode}

  defp not_recursive(@broker_tool), do: {:error, :broker_recursion}
  defp not_recursive(_tool), do: :ok

  defp known_tool(tool) do
    case ToolPolicy.fetch(tool) do
      {:ok, category} -> {:ok, category}
      :error -> {:error, :unknown_tool}
    end
  end

  defp in_capability_set(%{role: role}, tool) do
    if tool in Capabilities.authorized_routine_tool_names(role),
      do: :ok,
      else: {:error, :outside_capability_set}
  end

  defp read_only(:read), do: :ok
  defp read_only(_category), do: {:error, :not_read_only}

  defp audit(routine_id, requested_tool, decision, reason, snapshot) do
    correlation = correlation(routine_id, snapshot)

    %{
      event: "permission_decision",
      agent: routine_id || "?",
      requested_tool: bounded_tool(requested_tool),
      decision: Atom.to_string(decision),
      reason: Atom.to_string(reason),
      summary: audit_summary(decision, requested_tool, reason)
    }
    |> put_present(:execution_revision, value(snapshot, :execution_revision))
    |> put_present(:agent_generation, correlation.generation)
    |> put_present(:agent_turn_id, correlation.turn_id)
    |> put_present(:arc_id, correlation.arc_id)
    |> Custode.Feed.record()
  end

  defp correlation(routine_id, %{execution_revision: revision})
       when is_binary(routine_id) and is_binary(revision) do
    matching =
      routine_id
      |> Custode.ProviderJobs.active_turns()
      |> Enum.filter(&(value(&1.meta, :config_revision) == revision))

    case matching do
      [%Oban.Job{meta: meta}] ->
        %{
          generation: value(meta, :agent_generation),
          turn_id: value(meta, :agent_turn_id),
          arc_id: value(meta, :arc_id)
        }

      _none_or_ambiguous ->
        empty_correlation()
    end
  end

  defp correlation(_routine_id, _snapshot), do: empty_correlation()

  defp empty_correlation, do: %{generation: nil, turn_id: nil, arc_id: nil}

  defp bounded_tool(tool) when is_binary(tool),
    do: String.byte_slice(tool, 0, @audit_tool_limit)

  defp bounded_tool(_tool), do: "<malformed>"

  defp audit_summary(decision, requested_tool, reason) do
    "permission #{decision}: #{bounded_tool(requested_tool)} (#{reason})"
  end

  defp denial_message(:authenticated_routine_required),
    do: "permission denied: an authenticated routine connection is required"

  defp denial_message(:malformed_request),
    do: "permission denied: tool_name must be a non-empty string and input must be an object"

  defp denial_message(:authorization_unavailable),
    do: "permission denied: the routine authorization snapshot is unavailable"

  defp denial_message(:outside_custode),
    do: "permission denied: only tools on the local Custode MCP server are eligible"

  defp denial_message(:broker_recursion),
    do: "permission denied: the permission broker cannot authorize itself"

  defp denial_message(:unknown_tool), do: "permission denied: the Custode tool is unknown"

  defp denial_message(:outside_capability_set),
    do: "permission denied: the tool is outside this routine's capability set"

  defp denial_message(:not_read_only),
    do: "permission denied: only read-only Custode tools are eligible"

  defp routine_id(%{assigns: %{custode_identity: %{kind: :routine, id: id}}})
       when is_binary(id) and id != "",
       do: id

  defp routine_id(_frame), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end

defmodule Custode.MCP.PermissionTools.PermissionDecide do
  @moduledoc """
  Decide one Claude permission prompt for an authenticated routine.

  The response is Claude's documented decision object encoded in the single
  MCP text content block. Allowed requests echo the original input unchanged;
  denied requests return only a reason.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools, only: [reply: 2]

  alias Custode.MCP.PermissionTools

  schema do
    field(:tool_name, :string,
      required: true,
      description: "the exact Claude tool name requesting permission"
    )

    field(:input, :map,
      required: true,
      description: "the original tool input; echoed unchanged only when allowed"
    )

    field(:tool_use_id, :string, description: "optional Claude correlation id")
  end

  @impl true
  def execute(params, frame) do
    case PermissionTools.decide(params, frame) do
      {:allow, input, :ok} ->
        reply(frame, %{behavior: "allow", updatedInput: input})

      {:deny, message, :ok} ->
        reply(frame, %{behavior: "deny", message: message})
    end
  end
end
