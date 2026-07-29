defmodule Custode.WorkKind do
  @moduledoc """
  Versioned workflow rules applied after the generic WorkItem state floor.

  Implementations own phase vocabulary, legal phase movement, transition
  evidence, and deterministic next-command decisions. They never persist
  WorkItems themselves.
  """

  alias Custode.WorkItem

  @callback kind() :: String.t()
  @callback version() :: pos_integer()
  @callback phases() :: [String.t()]
  @callback validate_pair(String.t(), String.t()) :: :ok | {:error, term()}
  @callback validate_transition(WorkItem.t(), map(), map()) :: :ok | {:error, term()}
  @callback next_command(WorkItem.t(), map()) :: {:ok, map()} | {:error, term()}
end
