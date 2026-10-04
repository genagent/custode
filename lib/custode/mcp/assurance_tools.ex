defmodule Custode.MCP.AssuranceTools.Read do
  @moduledoc "Read scoped assurance predicates and immutable evidence/decision references. No effects."
  use Custode.MCP.Tool, name: "assurance_read"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  input_schema(%{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["case_id"],
    "properties" => %{"case_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160}}
  })

  @impl true
  def execute(%{case_id: id}, frame) do
    with {:ok, actor} <- actor(frame), {:ok, result} <- Custode.Assurance.read(actor, id) do
      reply(frame, result)
    else
      {:error, reason} -> fail(frame, "assurance read refused: #{inspect(reason)}")
    end
  end

  def execute(_params, frame), do: fail(frame, "case_id required")

  defp actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine] and is_binary(id) and id != "", do: {:ok, actor}

  defp actor(_frame), do: {:error, :unauthenticated}
end
