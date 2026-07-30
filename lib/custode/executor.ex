defmodule Custode.Executor do
  @moduledoc """
  Provider-neutral boundary for one bounded Attempt execution.

  The durable Attempt remains the identity and lifecycle source of truth.
  Adapters translate an immutable request into provider calls and normalize
  provider responses into these shared result and failure types. Delivery
  retries must reuse the request's `attempt_id`.

  Capability checks happen here, before an adapter is allowed to launch its
  provider. Provider-specific payloads may appear only under result evidence;
  they do not become core Attempt lifecycle state.
  """

  alias __MODULE__.{
    Cancellation,
    Capabilities,
    Failure,
    Heartbeat,
    Request,
    Result,
    Version
  }

  @type adapter :: module()

  @callback capabilities() :: Capabilities.t()
  @callback version() :: Version.t()

  @callback execute(Request.t(), keyword()) ::
              {:ok, Result.t()} | {:error, Failure.t()}

  @callback heartbeat(Request.t(), keyword()) ::
              {:ok, Heartbeat.t()} | {:error, Failure.t()}

  @callback cancel(Request.t(), term(), keyword()) ::
              {:ok, Cancellation.t()} | {:error, Failure.t()}

  defmodule Capabilities do
    @moduledoc "Capabilities declared by one Executor adapter."

    @enforce_keys [
      :provider,
      :executor_kinds,
      :tools,
      :operations,
      :isolation,
      :features
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            provider: String.t(),
            executor_kinds: [String.t()],
            tools: [String.t()],
            operations: [String.t()],
            isolation: [String.t()],
            features: [String.t()]
          }
  end

  defmodule Version do
    @moduledoc "Version report for an Executor adapter and its integration runtime."

    @enforce_keys [
      :provider,
      :adapter,
      :adapter_version,
      :runtime_version,
      :protocol_version
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            provider: String.t(),
            adapter: String.t(),
            adapter_version: String.t(),
            runtime_version: String.t(),
            protocol_version: String.t()
          }
  end

  defmodule Request do
    @moduledoc """
    Immutable provider-neutral inputs for one Attempt.

    `context_bundle` includes the already digest-verified body. `role_binding`
    is the snapshot copied into Attempt provenance, not a mutable live read.
    `recipe`, requirements, selection, limits, and instructions are ordinary
    normalized maps so future adapters do not need Claude-shaped flags.
    """

    @enforce_keys [
      :attempt_id,
      :work_item_id,
      :mission_id,
      :context_bundle,
      :role_binding,
      :recipe,
      :requirements,
      :selection,
      :limits,
      :workspace,
      :instructions,
      :output_contract,
      :delivery
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt_id: String.t(),
            work_item_id: String.t(),
            mission_id: String.t(),
            context_bundle: map(),
            role_binding: map() | nil,
            recipe: map(),
            requirements: map(),
            selection: map(),
            limits: map(),
            workspace: map(),
            instructions: map(),
            output_contract: map(),
            delivery: map()
          }

    @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) when is_map(attrs) or is_list(attrs) do
      attrs = Map.new(attrs)

      request =
        %__MODULE__{
          attempt_id: value(attrs, :attempt_id),
          work_item_id: value(attrs, :work_item_id),
          mission_id: value(attrs, :mission_id),
          context_bundle: normalize(value(attrs, :context_bundle)),
          role_binding: normalize(value(attrs, :role_binding)),
          recipe: normalize(value(attrs, :recipe)),
          requirements: normalize(value(attrs, :requirements) || %{}),
          selection: normalize(value(attrs, :selection) || %{}),
          limits: normalize(value(attrs, :limits) || %{}),
          workspace: normalize(value(attrs, :workspace) || %{}),
          instructions: normalize(value(attrs, :instructions) || %{}),
          output_contract: normalize(value(attrs, :output_contract) || %{}),
          delivery: normalize(value(attrs, :delivery) || %{})
        }

      with :ok <- nonempty_id(request.attempt_id, :attempt_id),
           :ok <- nonempty_id(request.work_item_id, :work_item_id),
           :ok <- nonempty_id(request.mission_id, :mission_id),
           :ok <- context_bundle(request.context_bundle),
           :ok <- optional_map(request.role_binding, :role_binding),
           :ok <- nonempty_map(request.recipe, :recipe),
           :ok <- required_map_fields(request),
           :ok <- execution_limits(request.limits) do
        {:ok, request}
      end
    end

    def new(_attrs), do: {:error, :invalid_executor_request}

    defp required_map_fields(request) do
      [:requirements, :selection, :limits, :workspace, :instructions, :output_contract, :delivery]
      |> Enum.find(&(not is_map(Map.fetch!(request, &1))))
      |> case do
        nil -> :ok
        field -> {:error, {:invalid_executor_request_field, field}}
      end
    end

    defp context_bundle(%{"id" => id, "digest" => digest, "body" => body})
         when is_binary(id) and id != "" and is_binary(digest) and digest != "" and
                is_map(body),
         do: :ok

    defp context_bundle(_bundle),
      do: {:error, {:invalid_executor_request_field, :context_bundle}}

    defp optional_map(nil, _field), do: :ok
    defp optional_map(value, _field) when is_map(value), do: :ok
    defp optional_map(_value, field), do: {:error, {:invalid_executor_request_field, field}}

    defp nonempty_map(value, _field) when is_map(value) and map_size(value) > 0, do: :ok
    defp nonempty_map(_value, field), do: {:error, {:invalid_executor_request_field, field}}

    defp nonempty_id(value, _field) when is_binary(value) and value != "", do: :ok
    defp nonempty_id(_value, field), do: {:error, {:invalid_executor_request_field, field}}

    defp execution_limits(limits) do
      with :ok <- positive_integer(limits["max_turns"], :max_turns),
           :ok <- positive_integer(limits["timeout_ms"], :timeout_ms) do
        optional_positive_number(limits["max_budget_usd"], :max_budget_usd)
      end
    end

    defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
    defp positive_integer(_value, field), do: {:error, {:invalid_executor_limit, field}}

    defp optional_positive_number(nil, _field), do: :ok

    defp optional_positive_number(value, _field) when is_number(value) and value > 0,
      do: :ok

    defp optional_positive_number(_value, field), do: {:error, {:invalid_executor_limit, field}}

    defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

    defp normalize(nil), do: nil

    defp normalize(map) when is_map(map),
      do: Map.new(map, fn {key, nested} -> {to_string(key), normalize(nested)} end)

    defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
    defp normalize(value) when is_atom(value), do: to_string(value)
    defp normalize(value), do: value
  end

  defmodule Failure do
    @moduledoc "Provider-neutral failure classification."

    @enforce_keys [:classification, :message, :retryable, :details]
    defstruct @enforce_keys

    @type classification ::
            :capability_mismatch
            | :provider_crash
            | :infrastructure
            | :timeout
            | :limit
            | :provider_refusal
            | :contract_violation

    @type t :: %__MODULE__{
            classification: classification(),
            message: String.t(),
            retryable: boolean(),
            details: map()
          }
  end

  defmodule Result do
    @moduledoc "Normalized result of one Executor invocation."

    @statuses [:succeeded, :failed, :cancelled, :rejected]

    @enforce_keys [
      :attempt_id,
      :status,
      :output,
      :usage,
      :continuation,
      :transcript_refs,
      :artifacts,
      :cancellation,
      :failure,
      :evidence,
      :executor
    ]
    defstruct @enforce_keys

    @type status :: :succeeded | :failed | :cancelled | :rejected

    @type t :: %__MODULE__{
            attempt_id: String.t(),
            status: status(),
            output: map() | nil,
            usage: map(),
            continuation: map() | nil,
            transcript_refs: [map()],
            artifacts: [map()],
            cancellation: map() | nil,
            failure: Failure.t() | nil,
            evidence: map(),
            executor: map()
          }

    @doc false
    def valid?(%__MODULE__{} = result) do
      result.status in @statuses and is_binary(result.attempt_id) and
        is_map(result.usage) and is_list(result.transcript_refs) and
        is_list(result.artifacts) and is_map(result.evidence) and is_map(result.executor) and
        valid_failure?(result)
    end

    defp valid_failure?(%{status: :succeeded, failure: nil}), do: true
    defp valid_failure?(%{failure: %Failure{}}), do: true
    defp valid_failure?(_result), do: false
  end

  defmodule Heartbeat do
    @moduledoc "Provider-neutral liveness observation for an Attempt execution."

    @enforce_keys [:attempt_id, :status, :observed_at, :details]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt_id: String.t(),
            status: :alive | :terminal | :unknown,
            observed_at: DateTime.t(),
            details: map()
          }
  end

  defmodule Cancellation do
    @moduledoc "Provider-neutral cancellation acknowledgement."

    @enforce_keys [:attempt_id, :status, :reason, :details]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt_id: String.t(),
            status: :requested | :already_terminal | :unsupported,
            reason: term(),
            details: map()
          }
  end

  @doc "Discover one adapter's capabilities."
  @spec capabilities(adapter()) :: {:ok, Capabilities.t()} | {:error, Failure.t()}
  def capabilities(adapter) when is_atom(adapter) do
    case safe_apply(adapter, :capabilities, []) do
      {:ok, %Capabilities{} = capabilities} -> {:ok, capabilities}
      {:ok, other} -> {:error, contract_failure(:capabilities, other)}
      {:error, failure} -> {:error, failure}
    end
  end

  @doc "Report one adapter and integration runtime version."
  @spec version(adapter()) :: {:ok, Version.t()} | {:error, Failure.t()}
  def version(adapter) when is_atom(adapter) do
    case safe_apply(adapter, :version, []) do
      {:ok, %Version{} = version} -> {:ok, version}
      {:ok, other} -> {:error, contract_failure(:version, other)}
      {:error, failure} -> {:error, failure}
    end
  end

  @doc "Validate capabilities, then invoke an adapter exactly once."
  @spec execute(adapter(), Request.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Failure.t()}
  def execute(adapter, %Request{} = request, options \\ []) when is_atom(adapter) do
    with {:ok, capabilities} <- capabilities(adapter) do
      case capability_check(request, capabilities) do
        :ok -> invoke_execute(adapter, request, options)
        {:error, details} -> {:ok, rejected_result(request, capabilities, details)}
      end
    end
  end

  @doc "Ask an adapter for a liveness observation tied to the same Attempt."
  @spec heartbeat(adapter(), Request.t(), keyword()) ::
          {:ok, Heartbeat.t()} | {:error, Failure.t()}
  def heartbeat(adapter, %Request{} = request, options \\ []) when is_atom(adapter) do
    adapter
    |> safe_apply(:heartbeat, [request, options])
    |> validate_control_result(Heartbeat, request.attempt_id, :heartbeat)
  end

  @doc "Request cancellation without creating a replacement Attempt."
  @spec cancel(adapter(), Request.t(), term(), keyword()) ::
          {:ok, Cancellation.t()} | {:error, Failure.t()}
  def cancel(adapter, %Request{} = request, reason, options \\ []) when is_atom(adapter) do
    adapter
    |> safe_apply(:cancel, [request, reason, options])
    |> validate_control_result(Cancellation, request.attempt_id, :cancel)
  end

  defp invoke_execute(adapter, request, options) do
    case safe_apply(adapter, :execute, [request, options]) do
      {:ok, {:ok, %Result{} = result}} ->
        validate_result(result, request)

      {:ok, {:error, %Failure{} = failure}} ->
        {:ok, failed_result(request, failure)}

      {:ok, other} ->
        {:ok, failed_result(request, contract_failure(:execute, other))}

      {:error, failure} ->
        {:ok, failed_result(request, failure)}
    end
  end

  defp validate_result(result, request) do
    cond do
      result.attempt_id != request.attempt_id ->
        {:ok,
         failed_result(
           request,
           contract_failure(:attempt_identity, %{
             expected: request.attempt_id,
             observed: result.attempt_id
           })
         )}

      not Result.valid?(result) ->
        {:ok, failed_result(request, contract_failure(:result, result))}

      true ->
        {:ok, result}
    end
  end

  defp validate_control_result({:ok, {:ok, struct}}, module, attempt_id, _callback)
       when is_struct(struct, module) do
    if struct.attempt_id == attempt_id,
      do: {:ok, struct},
      else: {:error, contract_failure(:attempt_identity, struct.attempt_id)}
  end

  defp validate_control_result({:ok, {:error, %Failure{} = failure}}, _module, _id, _callback),
    do: {:error, failure}

  defp validate_control_result({:ok, other}, _module, _id, callback),
    do: {:error, contract_failure(callback, other)}

  defp validate_control_result({:error, failure}, _module, _id, _callback),
    do: {:error, failure}

  defp capability_check(request, capabilities) do
    requirements = request.requirements

    missing =
      %{}
      |> mismatch("provider", requirements["provider"], [capabilities.provider])
      |> mismatch(
        "executor_kind",
        requirements["executor_kind"],
        capabilities.executor_kinds
      )
      |> missing_values("tools", requirements["tools"], capabilities.tools)
      |> missing_values("operations", requirements["operations"], capabilities.operations)
      |> missing_values("isolation", requirements["isolation"], capabilities.isolation)
      |> missing_values("features", requirements["features"], capabilities.features)

    if map_size(missing) == 0, do: :ok, else: {:error, missing}
  end

  defp mismatch(missing, _field, nil, _available), do: missing

  defp mismatch(missing, field, required, available) do
    if required in available,
      do: missing,
      else: Map.put(missing, field, %{required: required, available: available})
  end

  defp missing_values(missing, _field, nil, _available), do: missing

  defp missing_values(missing, field, required, available) when is_list(required) do
    case required -- available do
      [] -> missing
      absent -> Map.put(missing, field, %{required: required, missing: absent})
    end
  end

  defp missing_values(missing, field, required, available),
    do: Map.put(missing, field, %{required: required, available: available})

  defp rejected_result(request, capabilities, details) do
    failure = %Failure{
      classification: :capability_mismatch,
      message: "executor capabilities do not satisfy the Attempt",
      retryable: false,
      details: details
    }

    %Result{
      attempt_id: request.attempt_id,
      status: :rejected,
      output: nil,
      usage: %{},
      continuation: nil,
      transcript_refs: [],
      artifacts: [],
      cancellation: nil,
      failure: failure,
      evidence: %{},
      executor: %{provider: capabilities.provider}
    }
  end

  defp failed_result(request, failure) do
    %Result{
      attempt_id: request.attempt_id,
      status: :failed,
      output: nil,
      usage: %{},
      continuation: nil,
      transcript_refs: [],
      artifacts: [],
      cancellation: nil,
      failure: failure,
      evidence: %{},
      executor: %{}
    }
  end

  defp safe_apply(adapter, callback, arguments) do
    {:ok, apply(adapter, callback, arguments)}
  rescue
    exception ->
      {:error,
       %Failure{
         classification: :provider_crash,
         message: "executor adapter raised",
         retryable: true,
         details: %{
           adapter: inspect(adapter),
           callback: to_string(callback),
           exception: Exception.message(exception)
         }
       }}
  catch
    kind, reason ->
      {:error,
       %Failure{
         classification: :provider_crash,
         message: "executor adapter exited",
         retryable: true,
         details: %{
           adapter: inspect(adapter),
           callback: to_string(callback),
           kind: inspect(kind),
           reason: inspect(reason)
         }
       }}
  end

  defp contract_failure(callback, observed) do
    %Failure{
      classification: :contract_violation,
      message: "executor adapter violated the #{callback} contract",
      retryable: false,
      details: %{callback: to_string(callback), observed: inspect(observed)}
    }
  end
end
