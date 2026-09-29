defmodule Custode.Agents do
  @moduledoc """
  Provider-neutral lifecycle boundary for Custode's active agents.

  A configured routine selects its engine with `:provider`; unconfigured
  agents, including the current sub-agent surface, retain the historical
  Claude default. Agent ids remain fleet-wide identities, so callers do not
  need to carry a provider beside every operation.
  """

  @providers %{
    claude: ObanClaude.Agent,
    codex: ObanCodex.Agent,
    oban_claude: ObanClaude.Agent,
    oban_codex: ObanCodex.Agent
  }

  @doc "The configured provider for an agent id, defaulting to its live owner or Claude."
  def configured_provider(agent_id) do
    case Custode.Routine.get(agent_id) do
      %{provider: provider} -> provider
      nil -> active_provider(agent_id)
    end
  end

  @doc "The provider that currently owns the live lifecycle, or the configured provider offline."
  def execution_provider(agent_id) do
    case live_provider(agent_id) do
      {:ok, provider} -> provider
      :offline -> configured_provider(agent_id)
      {:error, :multiple_live_providers} = error -> error
    end
  end

  def provider(agent_id), do: execution_provider(agent_id)

  @doc "The sole live provider for an id, with split ownership reported explicitly."
  def live_provider(agent_id) do
    live =
      for {provider, module} <- [claude: ObanClaude.Agent, codex: ObanCodex.Agent],
          {:ok, status} = module.status(agent_id),
          Custode.state_of(status) != :offline,
          do: provider

    case live do
      [] -> :offline
      [provider] -> {:ok, provider}
      [_first, _second] -> {:error, :multiple_live_providers}
    end
  end

  @doc "The provider-specific scheduled tick worker for a routine."
  def tick_worker(%{provider: :claude}), do: ObanClaude.Agent.Tick
  def tick_worker(%{provider: :codex}), do: ObanCodex.Agent.Tick

  def start_agent(agent_id, config \\ []),
    do: call_provider(agent_id, :start_agent, [agent_id, config])

  @doc "Start through an explicitly selected provider during a safe handoff."
  def start_agent(agent_id, provider, config), do: module(provider).start_agent(agent_id, config)

  def stop_agent(agent_id), do: call_provider(agent_id, :stop_agent, [agent_id])

  @doc "Stop an agent through an explicitly captured provider, such as after roster removal."
  def stop_agent(agent_id, provider), do: module(provider).stop_agent(agent_id)

  def status(agent_id), do: call_provider(agent_id, :status, [agent_id])

  @doc "Read status through an explicitly captured provider."
  def status(agent_id, provider), do: module(provider).status(agent_id)

  @doc "Every live agent from both engines, in stable id order."
  def list do
    (ObanClaude.Agent.list() ++ ObanCodex.Agent.list())
    |> Enum.sort_by(&elem(&1, 0))
  end

  def await(agent_id, states, timeout \\ 60_000),
    do: call_provider(agent_id, :await, [agent_id, states, timeout])

  @doc "Await state through an explicitly selected provider."
  def await(agent_id, provider, states, timeout),
    do: module(provider).await(agent_id, states, timeout)

  def submit_prompt(agent_id, prompt, opts \\ []),
    do: call_provider(agent_id, :submit_prompt, [agent_id, prompt, opts])

  def cast_prompt(agent_id, prompt, opts \\ []),
    do: call_provider(agent_id, :cast_prompt, [agent_id, prompt, opts])

  @doc "Cast through an explicitly captured provider inside an admission boundary."
  def cast_prompt(agent_id, provider, prompt, opts),
    do: module(provider).cast_prompt(agent_id, prompt, opts)

  @doc """
  Forks a named conversation arc into another through the agent's provider.
  The source arc's handle is left unchanged.
  """
  def fork_arc(agent_id, source_arc_id, target_arc_id, prompt, opts \\ []),
    do: call_provider(agent_id, :fork_arc, [agent_id, source_arc_id, target_arc_id, prompt, opts])

  def approve_action(agent_id, action_id),
    do: call_provider(agent_id, :approve_action, [agent_id, action_id])

  def approve_action(agent_id, action_id, opts),
    do: call_provider(agent_id, :approve_action, [agent_id, action_id, opts])

  def reject_action(agent_id, action_id, reason \\ "denied"),
    do: call_provider(agent_id, :reject_action, [agent_id, action_id, reason])

  @doc "Arm the active provider turn to pause at its next safe boundary."
  def pause_after_turn(agent_id, reason, turn_meta) do
    serialize_pause(agent_id, %{cause: :pause_after_turn, reason: reason}, fn ->
      call_provider(agent_id, :pause_after_turn, [agent_id, reason, turn_meta])
    end)
  end

  @doc "Arm a turn through its explicitly captured provider."
  def pause_after_turn(agent_id, provider, reason, turn_meta) do
    serialize_pause(agent_id, %{cause: :pause_after_turn, reason: reason}, fn ->
      module(provider).pause_after_turn(agent_id, reason, turn_meta)
    end)
  end

  def emergency_pause(agent_id) do
    serialize_pause(agent_id, %{cause: :emergency_pause, reason: :emergency_pause}, fn ->
      call_provider(agent_id, :emergency_pause, [agent_id])
    end)
  end

  @doc "Pause through an explicitly selected provider inside a serialized handoff."
  def emergency_pause(agent_id, provider), do: module(provider).emergency_pause(agent_id)

  @doc "Pause through an explicitly selected provider while retaining durable pause provenance."
  def emergency_pause(agent_id, provider, context) when is_map(context),
    do: module(provider).emergency_pause(agent_id, context)

  def resume_agent(agent_id) do
    serialize_resume(agent_id, fn -> call_provider(agent_id, :resume_agent, [agent_id]) end)
  end

  @doc "Resume through an explicitly selected provider inside a serialized handoff."
  def resume_agent(agent_id, provider), do: module(provider).resume_agent(agent_id)
  def info(agent_id), do: call_provider(agent_id, :info, [agent_id])
  def info(agent_id, provider), do: module(provider).info(agent_id)
  def history(agent_id), do: call_provider(agent_id, :history, [agent_id])

  @doc "Atomically quiesce the live provider at its next safe lifecycle boundary."
  def quiesce(agent_id, provider, reason), do: module(provider).quiesce(agent_id, reason)

  defp call_provider(agent_id, function, args) do
    case provider(agent_id) do
      provider when provider in [:claude, :codex] -> apply(module(provider), function, args)
      {:error, reason} -> {:error, reason}
    end
  end

  defp module(provider), do: Map.fetch!(@providers, provider)

  defp serialize_pause(agent_id, context, fun) do
    if Custode.Routine.get(agent_id) do
      Custode.AgentHandoff.pause(agent_id, context, fun)
    else
      fun.()
    end
  end

  defp serialize_resume(agent_id, fun) do
    if not is_nil(Custode.Routine.get(agent_id)) and not handoff_owner?() do
      Custode.AgentHandoff.resume(agent_id, fun)
    else
      fun.()
    end
  end

  # Admission callbacks already run under the coordinator's ownership. A
  # paused durable delivery resumes there before submitting its prompt, so
  # re-entering the same GenServer would fail with :calling_self.
  defp handoff_owner?, do: Process.whereis(Custode.AgentHandoff) == self()

  # Once a routine has been removed from the live roster, cleanup still has
  # to find a Codex process that was started from the old entry. Unknown ids
  # otherwise remain Claude for sub-agent compatibility.
  defp active_provider(agent_id) do
    case live_provider(agent_id) do
      {:ok, provider} -> provider
      :offline -> :claude
      {:error, :multiple_live_providers} = error -> error
    end
  end
end
