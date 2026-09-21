defmodule Custode.Routine.Effort do
  @moduledoc """
  The routine effort vocabulary, normalized before config is saved or a turn
  is built. Strings from forms and TOML and atoms from Elixir config mean the
  same thing; arbitrary existing atoms are not valid effort settings.
  """

  @levels [:low, :medium, :high, :xhigh, :max]

  @type t :: :low | :medium | :high | :xhigh | :max

  @spec normalize(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}
  def normalize(value) when value in @levels, do: {:ok, value}

  def normalize(value) when is_binary(value) do
    case Enum.find(@levels, &(Atom.to_string(&1) == value)) do
      nil -> invalid(value)
      level -> {:ok, level}
    end
  end

  def normalize(value), do: invalid(value)

  @spec normalize!(term()) :: t() | nil
  def normalize!(value) do
    case normalize(value) do
      {:ok, level} -> level
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp invalid(value),
    do: {:error, "unknown effort #{inspect(value)}; expected low, medium, high, xhigh or max"}
end
