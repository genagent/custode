defmodule Custode.MCP.Capabilities do
  @moduledoc """
  Executable MCP capability policy.

  Endpoint admission, tool discovery, call authorization, and generated
  routine allowlists all read this module. Tool handlers and shared operations
  retain their narrower target, grant, and side-effect checks.
  """

  require Logger

  @behaviour Snodo.Authorization

  alias Anubis.MCP.Error, as: AnubisError
  alias Anubis.Server.Handlers
  alias Custode.AgentHandoff
  alias Snodo.Authorization.Component
  alias Snodo.Error, as: SnodoError

  @memory_tools ~w(journal_read remember recall forget)
  @permission_tools ~w(permission_decide)

  @worker_tools ~w(
    ask_operator
    list_routines agent_status start_agent prompt_agent await_agent
    agent_history approve_action reject_action run_job
    journal_append journal_read compact_journal
    todo_add todo_list todo_complete inbox_list inbox_mark_filed
    set_next_beat
    remember recall forget
    repo_open_pr repo_open_issue repo_draft_issues repo_file_drafts
    repo_comment repo_ready_pr repo_merge_pr
    repo_mark_issue_ready repo_mark_issue_blocked repo_review_pr
    repo_list_issues repo_view_issue repo_list_prs repo_view_pr
    repo_pr_checks repo_pr_diff
    repo_disown_pr repo_reclaim_pr
  )

  # Kept compact because these names enter every caretaker prompt. Human-only
  # ask decisions are deliberately absent even though older allowlists exposed
  # them; their handlers have always refused routine callers.
  @caretaker_exposed_tools ~w(
    list_asks list_disowned
    beat drop_note list_gates feed_tail pause_agent resume_agent spend_today
    preview_routine add_routine preview_routine_edit update_routine
    remove_routine
    preview_profile define_profile preview_profile_edit update_profile
    remove_profile
  )

  # Authorized for explicit use without spending prompt context on every
  # sweep. The caretaker is the fleet operator, while specialists remain
  # scoped to their worker bundle.
  @caretaker_on_demand_tools ~w(
    list_attention list_inbox list_suggestions list_suggestion_outcomes
    list_advisors metrics digest list_roles list_policies list_workflows
    executing_turns provision_owned_checkout refresh_owned_checkout
  )

  @type endpoint :: :main | :memory
  @type identity :: %{kind: :operator | :routine | :sub_agent, id: String.t()}

  @doc "Whether an authenticated identity may initialize this endpoint."
  @spec authorize_endpoint(endpoint(), identity()) :: :ok | {:error, String.t()}
  def authorize_endpoint(:main, %{kind: :operator}), do: :ok

  def authorize_endpoint(:main, %{kind: :routine, id: id}) do
    case AgentHandoff.authorization_role(id) do
      {:ok, _role} -> :ok
      {:error, :handoff_pending} -> {:error, "routine configuration handoff is pending"}
      {:error, :unknown_routine} -> {:error, "routine is not in the current roster"}
      {:error, _reason} -> {:error, "routine authorization is temporarily unavailable"}
    end
  end

  def authorize_endpoint(:memory, %{kind: :sub_agent}), do: :ok

  def authorize_endpoint(endpoint, %{kind: kind}) do
    {:error, "#{kind} identity may not use the #{endpoint} MCP endpoint"}
  end

  def authorize_endpoint(_endpoint, _identity),
    do: {:error, "authenticated MCP identity required"}

  @doc "The routine tools placed in a provider client's normal allowlist."
  @spec exposed_tool_names(atom()) :: [String.t()]
  def exposed_tool_names(role) do
    operator = if Custode.Roles.grants(role) == :operator, do: @caretaker_exposed_tools, else: []
    @worker_tools ++ operator ++ optional_tools()
  end

  @doc "Tool names a caller may discover and invoke at an endpoint."
  @spec authorized_tool_names(endpoint(), identity()) :: :all | [String.t()]
  def authorized_tool_names(:main, %{kind: :operator}), do: :all

  def authorized_tool_names(:main, %{kind: :routine, id: id}) do
    case AgentHandoff.authorization_role(id) do
      {:ok, role} when is_atom(role) ->
        authorized_routine_tool_names(role) ++ @permission_tools

      _unavailable ->
        []
    end
  end

  def authorized_tool_names(:memory, %{kind: :sub_agent}), do: @memory_tools
  def authorized_tool_names(_endpoint, _identity), do: []

  @doc false
  @spec authorized_routine_tool_names(atom()) :: [String.t()]
  def authorized_routine_tool_names(:caretaker),
    do: exposed_tool_names(:caretaker) ++ @caretaker_on_demand_tools

  def authorized_routine_tool_names(role) when is_atom(role), do: exposed_tool_names(role)

  @impl Snodo.Authorization
  def authorize(phase, %Component{} = component, context, endpoint)
      when phase in [:discovery, :invocation] and endpoint in [:main, :memory] do
    identity = get_in(context.auth, [:identity])

    with :ok <- authorize_endpoint(endpoint, identity),
         true <- component_allowed?(endpoint, identity, component) do
      :ok
    else
      false ->
        refuse_component(
          phase,
          endpoint,
          identity,
          component,
          "component is outside the caller's capability set"
        )

      {:error, reason} ->
        refuse_component(phase, endpoint, identity, component, reason)
    end
  end

  @doc false
  def handle_request(%{"method" => "tools/list"} = request, endpoint, server, frame) do
    identity = identity(frame)

    case authorize_endpoint(endpoint, identity) do
      :ok ->
        tools =
          server
          |> Handlers.get_server_tools(frame)
          |> Enum.filter(&tool_allowed?(endpoint, identity, &1.name))

        {tools, cursor} = Handlers.maybe_paginate(request, tools, frame.pagination_limit)

        result =
          if cursor,
            do: %{"tools" => tools, "nextCursor" => cursor},
            else: %{"tools" => tools}

        {:reply, result, frame}

      {:error, reason} ->
        refuse(endpoint, identity, "tools/list", reason, frame)
    end
  end

  def handle_request(
        %{"method" => "tools/call", "params" => %{"name" => name}} = request,
        endpoint,
        server,
        frame
      ) do
    identity = identity(frame)

    with :ok <- authorize_endpoint(endpoint, identity),
         true <- tool_allowed?(endpoint, identity, name) do
      Handlers.handle(request, server, frame)
    else
      false ->
        refuse(endpoint, identity, name, "tool is outside the caller's capability set", frame)

      {:error, reason} ->
        refuse(endpoint, identity, name, reason, frame)
    end
  end

  def handle_request(request, endpoint, server, frame) do
    identity = identity(frame)

    case authorize_endpoint(endpoint, identity) do
      :ok -> Handlers.handle(request, server, frame)
      {:error, reason} -> refuse(endpoint, identity, request["method"], reason, frame)
    end
  end

  defp tool_allowed?(endpoint, identity, name) do
    case authorized_tool_names(endpoint, identity) do
      :all -> true
      names -> name in names
    end
  end

  defp identity(%{assigns: %{custode_identity: identity}}), do: identity
  defp identity(_frame), do: nil

  defp optional_tools do
    if Custode.Panels.mode() == :off, do: [], else: ["set_panel"]
  end

  defp refuse(endpoint, identity, capability, reason, frame) do
    caller = if identity, do: "#{identity.kind}:#{identity.id}", else: "missing"

    Logger.warning(
      "MCP capability refused endpoint=#{endpoint} caller=#{caller} " <>
        "capability=#{inspect(capability)} reason=#{reason}"
    )

    message = "MCP capability refused: #{reason}"
    {:error, AnubisError.execution(message, %{endpoint: endpoint, capability: capability}), frame}
  end

  defp component_allowed?(endpoint, identity, %Component{kind: :tool, name: name}),
    do: tool_allowed?(endpoint, identity, name)

  defp component_allowed?(:main, %{kind: :operator}, %Component{
         kind: kind
       })
       when kind in [:resource, :resource_template],
       do: true

  defp component_allowed?(_endpoint, _identity, _component), do: false

  defp refuse_component(:discovery, _endpoint, _identity, _component, _reason),
    do: {:error, SnodoError.authorization(-32_003, "Not authorized")}

  defp refuse_component(:invocation, endpoint, identity, component, reason) do
    capability = component.uri || component.name
    caller = if identity, do: "#{identity.kind}:#{identity.id}", else: "missing"

    Logger.warning(
      "MCP capability refused endpoint=#{endpoint} caller=#{caller} " <>
        "capability=#{inspect(capability)} reason=#{reason}"
    )

    {:error,
     SnodoError.authorization(-32_003, "MCP capability refused: #{reason}", %{
       "endpoint" => Atom.to_string(endpoint),
       "capability" => capability
     })}
  end
end
