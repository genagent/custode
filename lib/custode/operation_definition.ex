defmodule Custode.OperationDefinition do
  @moduledoc """
  The inspectable contract for one transport-neutral control-plane operation.

  Schemas deliberately use a small map vocabulary in this first slice:
  `%{field: [type: :string, required: true]}`. The operation dispatcher owns
  validation so malformed input cannot reach a handler.
  """

  @type schema_type :: :string | :integer | :boolean | :map | :any
  @type schema :: %{optional(atom()) => keyword()}
  @type classification :: :query | :command
  @type risk :: :read | :internal_write | :external_write | :destructive

  @enforce_keys [
    :name,
    :input_schema,
    :result_schema,
    :classification,
    :risk,
    :required_grants,
    :authorization,
    :idempotency,
    :handler,
    :audit,
    :projection
  ]
  defstruct @enforce_keys ++ [effect_preview: nil, precondition: nil, reconcile: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          input_schema: schema(),
          result_schema: schema(),
          classification: classification(),
          risk: risk(),
          required_grants: [atom()],
          authorization: (t(), Custode.OperationEnvelope.t() ->
                            {:ok, atom()} | {:error, term()}),
          idempotency: map(),
          effect_preview:
            nil | (map(), Custode.OperationEnvelope.t() -> {:ok, term()} | {:error, term()}),
          precondition:
            nil
            | (map(), Custode.OperationEnvelope.t() ->
                 :ok | {:stale, term(), map()}),
          reconcile:
            nil
            | (Custode.OperationCall.t() ->
                 :retry | {:ok, map(), [map()]} | {:waiting, term()}),
          handler: (map(), Custode.OperationEnvelope.t() ->
                      {:ok, map()} | {:ok, map(), [map()]} | {:error, term()}),
          audit: (map() -> String.t()),
          projection: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    definition = struct(__MODULE__, attrs)

    with :ok <- validate_name(definition.name),
         :ok <- validate_schema(definition.input_schema),
         :ok <- validate_schema(definition.result_schema),
         true <- definition.classification in [:query, :command],
         true <- definition.risk in [:read, :internal_write, :external_write, :destructive],
         true <- is_list(definition.required_grants),
         true <- is_function(definition.authorization, 2),
         true <- is_map(definition.idempotency),
         true <- is_nil(definition.effect_preview) or is_function(definition.effect_preview, 2),
         true <- is_nil(definition.precondition) or is_function(definition.precondition, 2),
         true <- is_nil(definition.reconcile) or is_function(definition.reconcile, 1),
         true <- is_function(definition.handler, 2),
         true <- is_function(definition.audit, 1),
         true <- is_map(definition.projection) do
      {:ok, definition}
    else
      false -> {:error, :invalid_definition}
      {:error, _reason} = error -> error
    end
  rescue
    KeyError -> {:error, :invalid_definition}
  end

  def new(_attrs), do: {:error, :invalid_definition}

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, name),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_schema(schema) when is_map(schema) do
    if Enum.all?(schema, fn
         {key, options} when is_atom(key) and is_list(options) ->
           Keyword.get(options, :type, :any) in [:string, :integer, :boolean, :map, :any] and
             Keyword.get(options, :required, false) in [true, false]

         _other ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_schema}
  end

  defp validate_schema(_schema), do: {:error, :invalid_schema}
end
