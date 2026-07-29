defmodule Custode.OperationEnvelope do
  @moduledoc """
  Transport-neutral invocation context.

  Actor identity is intentionally independent from transport: for example,
  `%{kind: :routine, id: "custode"}` may invoke through `:mcp`.
  """

  @transports [:liveview, :mcp, :cli, :worker, :advisor, :caretaker, :system]

  @enforce_keys [:operation, :arguments, :actor, :transport]
  defstruct @enforce_keys ++
              [
                :mission_id,
                :work_item_id,
                :attempt_id,
                :grant,
                :idempotency_key,
                :expected_versions,
                :correlation_id,
                :causation_id,
                dry_run: false
              ]

  @type actor :: %{required(:kind) => atom(), required(:id) => String.t()}
  @type t :: %__MODULE__{
          operation: String.t(),
          arguments: map(),
          actor: actor(),
          transport: atom(),
          mission_id: term(),
          work_item_id: term(),
          attempt_id: term(),
          grant: atom() | nil,
          idempotency_key: String.t() | nil,
          expected_versions: map() | nil,
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil,
          dry_run: boolean()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    envelope = struct(__MODULE__, attrs)

    with :ok <- valid?(is_binary(envelope.operation), :operation),
         :ok <- valid?(is_map(envelope.arguments), :arguments),
         :ok <- valid?(valid_actor?(envelope.actor), :actor),
         :ok <- valid?(envelope.transport in @transports, :transport),
         :ok <- valid?(is_boolean(envelope.dry_run), :dry_run),
         :ok <- valid?(optional_binary?(envelope.correlation_id), :correlation_id),
         :ok <- valid?(optional_binary?(envelope.causation_id), :causation_id) do
      {:ok, envelope}
    end
  rescue
    KeyError -> {:error, :invalid_envelope}
  end

  def new(_attrs), do: {:error, :invalid_envelope}

  defp valid_actor?(%{kind: kind, id: id}) when is_atom(kind) and is_binary(id), do: id != ""
  defp valid_actor?(_actor), do: false

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value) and value != ""

  defp valid?(true, _field), do: :ok
  defp valid?(false, field), do: {:error, {:invalid_envelope, field}}
end
