defmodule Custode.AttemptWorker do
  @moduledoc """
  One bounded worker declaration for durable Attempt delivery.

  The declaration is scheduling capability, not work identity. Attempts and
  WorkItems remain authoritative while a worker says only which immutable
  requirements it can satisfy and how many matching Attempts it may run.
  """

  @enforce_keys [
    :name,
    :commands,
    :executor_kinds,
    :providers,
    :repositories,
    :tools,
    :operations,
    :isolation,
    :features,
    :max_concurrency,
    :handler
  ]
  defstruct @enforce_keys

  @type repository_scope :: :any | [String.t()]

  @type t :: %__MODULE__{
          name: String.t(),
          commands: [String.t()],
          executor_kinds: [String.t()],
          providers: [String.t()],
          repositories: repository_scope(),
          tools: [String.t()],
          operations: [String.t()],
          isolation: [String.t()],
          features: [String.t()],
          max_concurrency: pos_integer(),
          handler: module()
        }

  @type requirements :: %{
          required(:command) => String.t(),
          required(:executor_kind) => String.t(),
          required(:provider) => String.t(),
          required(:repository_id) => String.t() | nil,
          required(:tools) => [String.t()],
          required(:operations) => [String.t()],
          required(:isolation) => String.t(),
          required(:features) => [String.t()]
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    worker = struct(__MODULE__, attrs)

    with :ok <- name(worker.name),
         :ok <- nonempty_strings(worker.commands),
         :ok <- nonempty_strings(worker.executor_kinds),
         :ok <- nonempty_strings(worker.providers),
         :ok <- repositories(worker.repositories),
         :ok <- strings(worker.tools),
         :ok <- strings(worker.operations),
         :ok <- nonempty_strings(worker.isolation),
         :ok <- strings(worker.features),
         true <- is_integer(worker.max_concurrency) and worker.max_concurrency > 0,
         true <- is_atom(worker.handler) do
      {:ok, worker}
    else
      false -> {:error, :invalid_attempt_worker}
      {:error, _reason} = error -> error
    end
  rescue
    KeyError -> {:error, :invalid_attempt_worker}
  end

  def new(_attrs), do: {:error, :invalid_attempt_worker}

  @spec matches?(t(), requirements()) :: boolean()
  def matches?(%__MODULE__{} = worker, requirements) when is_map(requirements) do
    requirements.command in worker.commands and
      requirements.executor_kind in worker.executor_kinds and
      requirements.provider in worker.providers and
      repository_matches?(worker.repositories, requirements.repository_id) and
      subset?(requirements.tools, worker.tools) and
      subset?(requirements.operations, worker.operations) and
      requirements.isolation in worker.isolation and
      subset?(requirements.features, worker.features)
  end

  defp repository_matches?(:any, repository_id), do: is_binary(repository_id)

  defp repository_matches?(repositories, repository_id),
    do: repository_id in repositories

  defp subset?(required, available), do: required -- available == []

  defp name(value) when is_binary(value) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, value),
      do: :ok,
      else: {:error, :invalid_worker_name}
  end

  defp name(_value), do: {:error, :invalid_worker_name}

  defp repositories(:any), do: :ok
  defp repositories(values), do: nonempty_strings(values)

  defp nonempty_strings(values) when is_list(values) and values != [], do: strings(values)
  defp nonempty_strings(_values), do: {:error, :invalid_attempt_worker}

  defp strings(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_attempt_worker}
  end

  defp strings(_values), do: {:error, :invalid_attempt_worker}
end
