defmodule Custode.AttemptWorkerRegistry do
  @moduledoc "Deterministic, immutable lookup for bounded Attempt workers."

  alias Custode.{AttemptWorker, Executor}
  alias Custode.AttemptWorkers.GitHubIssue
  alias Custode.Executors.{Claude, Codex}

  @enforce_keys [:workers]
  defstruct [:workers]

  @type t :: %__MODULE__{workers: %{String.t() => AttemptWorker.t()}}

  @spec new([AttemptWorker.t()]) :: {:ok, t()} | {:error, term()}
  def new(workers) when is_list(workers) do
    Enum.reduce_while(workers, {:ok, %{}}, fn
      %AttemptWorker{name: name} = worker, {:ok, acc} ->
        if Map.has_key?(acc, name) do
          {:halt, {:error, {:duplicate_attempt_worker, name}}}
        else
          {:cont, {:ok, Map.put(acc, name, worker)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_attempt_worker}}
    end)
    |> case do
      {:ok, workers_by_name} -> {:ok, %__MODULE__{workers: workers_by_name}}
      error -> error
    end
  end

  @spec default() :: t()
  def default do
    %Executor.Capabilities{} = claude = Claude.capabilities()
    %Executor.Capabilities{} = codex = Codex.capabilities()

    {:ok, deterministic} =
      AttemptWorker.new(
        name: "local.custode",
        commands: ~w(prepare_workspace verify repair handle_feedback resolve_conflict publish),
        executor_kinds: ["deterministic"],
        providers: ["custode"],
        repositories: :any,
        tools: [],
        operations: ["git.publish_branch", "github.open_pr"],
        isolation: ["workspace_provisioning", "owned_worktree"],
        features: ["cancellation", "heartbeat", "timeout"],
        max_concurrency: limit(:custode, 3),
        handler: GitHubIssue
      )

    {:ok, model} =
      AttemptWorker.new(
        name: "local.claude",
        commands: ~w(implement repair handle_feedback resolve_conflict),
        executor_kinds: claude.executor_kinds,
        providers: [claude.provider],
        repositories: :any,
        tools: claude.tools,
        operations: claude.operations,
        isolation: claude.isolation,
        features: claude.features,
        max_concurrency: limit(:claude, 3),
        handler: GitHubIssue
      )

    {:ok, codex_model} =
      AttemptWorker.new(
        name: "local.codex",
        commands: ~w(implement repair handle_feedback resolve_conflict),
        executor_kinds: codex.executor_kinds,
        providers: [codex.provider],
        repositories: :any,
        tools: codex.tools,
        operations: codex.operations,
        isolation: codex.isolation,
        features: codex.features,
        max_concurrency: limit(:codex, 3),
        handler: GitHubIssue
      )

    {:ok, registry} = new([deterministic, model, codex_model])
    registry
  end

  @spec fetch(t(), String.t()) :: {:ok, AttemptWorker.t()} | :error
  def fetch(%__MODULE__{workers: workers}, name), do: Map.fetch(workers, name)

  @spec list(t()) :: [AttemptWorker.t()]
  def list(%__MODULE__{workers: workers}) do
    workers
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec eligible(t(), AttemptWorker.requirements()) :: [AttemptWorker.t()]
  def eligible(%__MODULE__{} = registry, requirements) do
    registry
    |> list()
    |> Enum.filter(&AttemptWorker.matches?(&1, requirements))
  end

  defp limit(kind, default) do
    :custode
    |> Application.get_env(:attempt_worker_limits, [])
    |> Keyword.get(kind, default)
  end
end
