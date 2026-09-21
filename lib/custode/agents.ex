defmodule Custode.Agents do
  @moduledoc """
  The lifecycle boundary used by Custode's active application (#581).

  The backend is currently `ObanClaude.Agent`. These delegates preserve its
  identities, return values, synchronous versus cast behavior, and options.
  In particular, prompt `:session` / `:origin` options and approval `:args`
  overrides reach the engine unchanged. No provider registry or routing
  policy is introduced here.

  This module contains no operator rules: UI and MCP operator message paths
  use `Custode.Operator.Actions.message/3`, which handles offline and paused
  agents before calling this boundary. Existing legacy LiveView casts retain
  their current semantics; consolidating those message paths is separate
  work.

  ## Remaining provider seams (#452)

  `Custode.Application` still starts the Claude engine supervisor. The
  console, operator actions, inbox and routine scheduler still construct
  `ObanClaude.Agent.Tick` jobs, `Custode.Routine` still builds Claude args,
  and one-shot/workflow workers still use `ObanClaude.Worker`. Those paths,
  provider identity and token rails belong to Codex activation. The frozen
  work kernel is unchanged.

  Codex's current `approve_action/2` does not accept the one-turn argument
  overrides of Claude's `approve_action/3`. Activation must resolve that
  contract; dropping the options is not a compatible adapter.
  """

  defdelegate start_agent(agent_id, config \\ []), to: ObanClaude.Agent
  defdelegate stop_agent(agent_id), to: ObanClaude.Agent
  defdelegate status(agent_id), to: ObanClaude.Agent
  defdelegate list(), to: ObanClaude.Agent
  defdelegate await(agent_id, states, timeout \\ 60_000), to: ObanClaude.Agent
  defdelegate submit_prompt(agent_id, prompt, opts \\ []), to: ObanClaude.Agent
  defdelegate cast_prompt(agent_id, prompt, opts \\ []), to: ObanClaude.Agent

  # Keep the two-argument call available independently of the newer options
  # arity. Custode.approve_action/3 only uses options for an actual override.
  defdelegate approve_action(agent_id, action_id), to: ObanClaude.Agent
  defdelegate approve_action(agent_id, action_id, opts), to: ObanClaude.Agent

  defdelegate reject_action(agent_id, action_id, reason \\ "denied"), to: ObanClaude.Agent
  defdelegate emergency_pause(agent_id), to: ObanClaude.Agent
  defdelegate resume_agent(agent_id), to: ObanClaude.Agent
  defdelegate info(agent_id), to: ObanClaude.Agent
  defdelegate history(agent_id), to: ObanClaude.Agent
end
