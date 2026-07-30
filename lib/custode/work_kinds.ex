defmodule Custode.WorkKinds do
  @moduledoc "Deterministic lookup and dispatch for versioned work-kind behavior."

  alias Custode.WorkItem
  alias Custode.WorkKinds.GithubIssueToMerge
  alias Custode.WorkKinds.SystemicDriftControl

  @definitions [GithubIssueToMerge.V1, SystemicDriftControl.V1]

  @spec fetch(String.t(), pos_integer()) :: {:ok, module()} | {:error, term()}
  def fetch(kind, version) do
    case Enum.find(@definitions, &(&1.kind() == kind and &1.version() == version)) do
      nil -> {:error, {:unknown_work_kind, "#{kind}@#{version}"}}
      module -> {:ok, module}
    end
  end

  @spec validate_pair(String.t(), pos_integer(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def validate_pair(kind, version, state, phase) do
    with {:ok, module} <- fetch(kind, version) do
      module.validate_pair(state, phase)
    end
  end

  @spec validate_transition(WorkItem.t(), map(), map()) :: :ok | {:error, term()}
  def validate_transition(%WorkItem{} = work_item, target, evidence) do
    with {:ok, module} <- fetch(work_item.kind, work_item.workflow_version) do
      module.validate_transition(work_item, target, evidence)
    end
  end

  @spec next_command(WorkItem.t(), map()) :: {:ok, map()} | {:error, term()}
  def next_command(%WorkItem{} = work_item, world_snapshot \\ %{}) do
    with {:ok, module} <- fetch(work_item.kind, work_item.workflow_version) do
      module.next_command(work_item, world_snapshot)
    end
  end
end
