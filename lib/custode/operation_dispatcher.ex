defmodule Custode.OperationDispatcher do
  @moduledoc "Validates, authorizes, previews, and invokes registered operations."

  alias Custode.{OperationDefinition, OperationEnvelope, OperationRegistry}

  @spec dispatch(map() | keyword() | OperationEnvelope.t(), OperationRegistry.t()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(envelope_or_attrs, registry \\ OperationRegistry.default()) do
    with {:ok, envelope} <- normalize_envelope(envelope_or_attrs),
         {:ok, definition} <- fetch(registry, envelope.operation),
         {:ok, arguments} <- validate(definition.input_schema, envelope.arguments),
         {:ok, grant} <- definition.authorization.(definition, envelope),
         :ok <- require_grant(definition, grant) do
      envelope = %{envelope | arguments: arguments, grant: grant}
      invoke(definition, envelope)
    end
  end

  defp normalize_envelope(%OperationEnvelope{} = envelope),
    do: OperationEnvelope.new(Map.from_struct(envelope))

  defp normalize_envelope(attrs), do: OperationEnvelope.new(attrs)

  defp fetch(registry, name) do
    case OperationRegistry.fetch(registry, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_operation, name}}
    end
  end

  defp require_grant(%OperationDefinition{required_grants: grants}, grant) do
    if grant in grants, do: :ok, else: {:error, {:denied, :missing_grant}}
  end

  defp invoke(%OperationDefinition{} = definition, %{dry_run: true} = envelope) do
    case definition.effect_preview do
      nil ->
        {:error, {:dry_run_unsupported, definition.name}}

      preview ->
        with {:ok, effect} <- preview.(envelope.arguments, envelope) do
          {:ok, response(envelope, :dry_run, nil, effect)}
        end
    end
  end

  defp invoke(%OperationDefinition{} = definition, envelope) do
    case definition.handler.(envelope.arguments, envelope) do
      {:ok, result} ->
        with {:ok, validated_result} <- validate(definition.result_schema, result) do
          {:ok, response(envelope, :succeeded, validated_result, nil)}
        end

      {:error, reason} ->
        {:error, {:handler_failed, reason}}

      other ->
        {:error, {:invalid_handler_result, other}}
    end
  end

  defp response(envelope, status, result, effect) do
    %{
      status: status,
      operation: envelope.operation,
      result: result,
      effect_preview: effect,
      actor: envelope.actor,
      transport: envelope.transport,
      grant: envelope.grant,
      correlation_id: envelope.correlation_id,
      causation_id: envelope.causation_id
    }
  end

  defp validate(schema, values) when is_map(values) do
    known_keys = Map.keys(schema) ++ Enum.map(Map.keys(schema), &Atom.to_string/1)
    unknown = Map.keys(values) -- known_keys

    errors = Enum.flat_map(schema, &validate_field(&1, values))

    errors = errors ++ Enum.map(unknown, &{&1, :unknown})

    if errors == [] do
      normalized =
        Enum.reduce(Map.keys(schema), %{}, &put_validated_field(&2, &1, values))

      {:ok, normalized}
    else
      {:error, {:validation_failed, Enum.sort(errors)}}
    end
  end

  defp fetch_value(values, field) do
    case Map.fetch(values, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(values, Atom.to_string(field))
    end
  end

  defp put_validated_field(acc, field, values) do
    case fetch_value(values, field) do
      {:ok, value} -> Map.put(acc, field, value)
      :error -> acc
    end
  end

  defp validate_field({field, options}, values) do
    case fetch_value(values, field) do
      :error ->
        if Keyword.get(options, :required, false), do: [{field, :required}], else: []

      {:ok, value} ->
        if valid_type?(value, Keyword.get(options, :type, :any)),
          do: [],
          else: [{field, :invalid_type}]
    end
  end

  defp valid_type?(_value, :any), do: true
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :map), do: is_map(value)
end
