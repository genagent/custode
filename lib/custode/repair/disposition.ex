defmodule Custode.Repair.Disposition do
  @moduledoc "One typed policy decision for a failed repository Attempt."

  @kinds ~w(
    infrastructure_retry
    mechanical_repair
    semantic_repair
    human_ask
    terminal_block
  )

  @enforce_keys [:kind, :reason, :source_attempt_id, :failure_artifact_id]
  defstruct [
    :kind,
    :reason,
    :source_attempt_id,
    :failure_artifact_id,
    :handler,
    :question
  ]

  @type kind :: String.t()

  @type t :: %__MODULE__{
          kind: kind(),
          reason: String.t(),
          source_attempt_id: String.t(),
          failure_artifact_id: String.t(),
          handler: String.t() | nil,
          question: String.t() | nil
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize(attrs)

    disposition = %__MODULE__{
      kind: normalize_kind(attrs[:kind]),
      reason: attrs[:reason],
      source_attempt_id: attrs[:source_attempt_id],
      failure_artifact_id: attrs[:failure_artifact_id],
      handler: attrs[:handler],
      question: attrs[:question]
    }

    with :ok <- member(disposition.kind),
         :ok <- required(:reason, disposition.reason),
         :ok <- required(:source_attempt_id, disposition.source_attempt_id),
         :ok <- required(:failure_artifact_id, disposition.failure_artifact_id),
         :ok <- handler_policy(disposition),
         :ok <- question_policy(disposition) do
      {:ok, disposition}
    end
  end

  def new(_attrs), do: {:error, :invalid_repair_disposition}

  @spec render(t()) :: map()
  def render(%__MODULE__{} = disposition) do
    disposition
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def kinds, do: @kinds

  defp member(kind) when kind in @kinds, do: :ok
  defp member(kind), do: {:error, {:unknown_repair_disposition, kind}}

  defp required(_field, value) when is_binary(value) and value != "", do: :ok
  defp required(field, _value), do: {:error, {:repair_disposition_field_required, field}}

  defp handler_policy(%{kind: "infrastructure_retry", handler: "verification_retry"}), do: :ok
  defp handler_policy(%{kind: "mechanical_repair", handler: "elixir_format"}), do: :ok
  defp handler_policy(%{kind: "semantic_repair", handler: "claude"}), do: :ok

  defp handler_policy(%{kind: kind, handler: nil}) when kind in ~w(human_ask terminal_block),
    do: :ok

  defp handler_policy(%{kind: kind, handler: handler}),
    do: {:error, {:invalid_repair_handler, %{kind: kind, handler: handler}}}

  defp question_policy(%{kind: "human_ask", question: question}),
    do: required(:question, question)

  defp question_policy(%{question: nil}), do: :ok

  defp question_policy(%{kind: kind}),
    do: {:error, {:repair_question_not_allowed, kind}}

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind), do: kind

  defp atomize(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_binary(key) ->
        case key do
          "kind" -> {:kind, value}
          "reason" -> {:reason, value}
          "source_attempt_id" -> {:source_attempt_id, value}
          "failure_artifact_id" -> {:failure_artifact_id, value}
          "handler" -> {:handler, value}
          "question" -> {:question, value}
          _other -> {key, value}
        end

      pair ->
        pair
    end)
  end
end
