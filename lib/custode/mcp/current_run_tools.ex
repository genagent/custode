defmodule Custode.MCP.CurrentRunTools.Read do
  @moduledoc "Read independently observed execution, queued input and retained helper references."

  use Custode.MCP.Tool, name: "current_run"

  import Custode.MCP.Tools, only: [fail: 2, need: 3, reply: 2]

  alias Custode.CurrentRun

  input_schema(%{
    "properties" => %{
      "routine_id" => %{
        "description" => "required configured project routine id",
        "type" => "string"
      }
    },
    "type" => "object"
  })

  @impl true
  def execute(params, frame) do
    with {:ok, actor} <- verified_actor(frame),
         {:ok, routine_id} <- need(params, :routine_id, "the configured project routine id"),
         {:ok, progress} <- CurrentRun.read(actor, routine_id) do
      reply(frame, progress)
    else
      {:error, reason} -> fail(frame, error_text(reason))
    end
  end

  defp verified_actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine, :sub_agent] and is_binary(id) and id != "",
       do: {:ok, actor}

  defp verified_actor(_frame), do: {:error, :unauthenticated}

  defp error_text(:unauthenticated), do: "current_run requires an authenticated MCP identity"
  defp error_text(:invalid_routine_id), do: "routine_id must be a nonempty configured routine id"

  defp error_text(:unknown_routine),
    do: "unknown project routine; use list_routines for valid ids"

  defp error_text(reason) when is_binary(reason), do: reason
end
