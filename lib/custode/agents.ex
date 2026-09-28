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

  @doc "The configured provider for an agent id, defaulting to Claude."
  def provider(agent_id) do
    case Custode.Routine.get(agent_id) do
      %{provider: provider} -> provider
      nil -> active_provider(agent_id)
    end
  end

  @doc "The provider-specific scheduled tick worker for a routine."
  def tick_worker(%{provider: :claude}), do: ObanClaude.Agent.Tick
  def tick_worker(%{provider: :codex}), do: ObanCodex.Agent.Tick

  def start_agent(agent_id, config \\ []),
    do: call_provider(agent_id, :start_agent, [agent_id, config])

  def stop_agent(agent_id), do: stop_agent(agent_id, provider(agent_id))

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

  def submit_prompt(agent_id, prompt, opts \\ []),
    do: call_provider(agent_id, :submit_prompt, [agent_id, prompt, opts])

  def cast_prompt(agent_id, prompt, opts \\ []),
    do: call_provider(agent_id, :cast_prompt, [agent_id, prompt, opts])

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
  def pause_after_turn(agent_id, reason, turn_meta),
    do: call_provider(agent_id, :pause_after_turn, [agent_id, reason, turn_meta])

  @doc "Arm a turn through its explicitly captured provider."
  def pause_after_turn(agent_id, provider, reason, turn_meta) do
    provider_module = module(provider)
    provider_module.pause_after_turn(agent_id, reason, turn_meta)
  end

  def emergency_pause(agent_id), do: call_provider(agent_id, :emergency_pause, [agent_id])
  def resume_agent(agent_id), do: call_provider(agent_id, :resume_agent, [agent_id])
  def info(agent_id), do: call_provider(agent_id, :info, [agent_id])
  def history(agent_id), do: call_provider(agent_id, :history, [agent_id])

  defp call_provider(agent_id, function, args),
    do: apply(module(provider(agent_id)), function, args)

  defp module(provider), do: Map.fetch!(@providers, provider)

  # Once a routine has been removed from the live roster, cleanup still has
  # to find a Codex process that was started from the old entry. Unknown ids
  # otherwise remain Claude for sub-agent compatibility.
  defp active_provider(agent_id) do
    case ObanCodex.Agent.status(agent_id) do
      {:ok, :offline} -> :claude
      {:ok, _live} -> :codex
    end
  end
end
