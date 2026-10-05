defmodule Custode.Workflow.Definition do
  @moduledoc "A data-only snapshot of the definition actually launched."

  @doc "Capture ordered stages, prompts, schemas and configured settings without interning names."
  def snapshot(definition) do
    body = definition |> normalize() |> omit_default_profile()

    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary(body)) |> Base.encode16(case: :lower)

    Map.put(body, "fingerprint", fingerprint)
  end

  # Adding an opt-in field must not invalidate already captured default definitions.
  defp omit_default_profile(%{"execution_profile" => nil} = body),
    do: Map.delete(body, "execution_profile")

  defp omit_default_profile(body), do: body

  defp normalize(%_{} = value), do: value |> Map.from_struct() |> normalize()

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), normalize(v)} end)

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when value in [nil, true, false], do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
end
