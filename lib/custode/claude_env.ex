defmodule Custode.ClaudeEnv do
  @moduledoc """
  Environment the `claude` CLI needs, set once at boot (#483).

  An agent's turn is a `claude` subprocess, and a subprocess inherits the
  node's OS environment. That makes the node's environment the one place a
  CLI setting can be fixed for every agent at once.

  Today that is one variable. The CLI's tool search defers MCP tool schemas
  by default: the model sees tool names and has to fetch a schema before it
  knows a tool's parameters. Agents call blind first. On the first live boot
  with `claude` 2.1.273, every sweep wasted its opening calls on "Invalid
  params", and `tower-resilience` never loaded `journal_append`, guessed
  `text` and then `entry` for its `body`, gave up, and reported the sweep as
  not journaled. A journal entry is the agent's memory of what it did.

  `ENABLE_TOOL_SEARCH=false` loads every tool definition up front. It costs
  context on every turn, about forty schemas for a worker. Deferral saves
  that and costs correctness, and an agent that cannot journal is not saving
  anything.

  A variable the operator already exported wins, so
  `ENABLE_TOOL_SEARCH=auto:20 mix phx.server` still does what it says.
  """

  require Logger

  @default %{"ENABLE_TOOL_SEARCH" => "false"}

  @doc "The configured variables: `config :custode, claude_env: %{...}`."
  @spec configured() :: %{String.t() => String.t()}
  def configured, do: Application.get_env(:custode, :claude_env, @default)

  @doc """
  Put each configured variable into the OS environment unless it is already
  set. Returns the ones it set.
  """
  @spec apply!() :: %{String.t() => String.t()}
  def apply! do
    set =
      for {name, value} <- configured(), System.get_env(name) == nil, into: %{} do
        System.put_env(name, value)
        {name, value}
      end

    if set != %{} do
      Logger.info("claude env set for agent turns: " <> Enum.map_join(set, " ", &pair/1))
    end

    set
  end

  defp pair({name, value}), do: "#{name}=#{value}"
end
