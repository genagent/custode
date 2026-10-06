defmodule Custode.MCP.ProjectProgressTools.Read do
  @moduledoc """
  Read one configured project's current execution, continuity, pending input,
  blockers, bounded work agreements and full direct-operator exchanges. Only the authenticated operator
  or caretaker may inspect this coordination view. It grants no sibling
  control and does not widen participant-only peer-message access.

  Omit before for fresh evidence before a coordination decision. Follow the
  returned conversation.before to read older exchanges at the same row
  watermark; older pages are not a replacement for refreshing the latest page.
  """

  use Custode.MCP.Tool, name: "project_progress"

  import Custode.MCP.Tools, only: [fail: 2, need: 3, reply: 2]

  alias Custode.ProjectProgress

  input_schema(%{
    "properties" => %{
      "before" => %{
        "description" =>
          "opaque conversation.before from the preceding page for this routine; omit for fresh evidence",
        "type" => "string"
      },
      "limit" => %{"description" => "exchanges per page, 1..20; default 5", "type" => "integer"},
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
         {:ok, progress} <- ProjectProgress.read(actor, routine_id, options(params)) do
      reply(frame, progress)
    else
      {:error, reason} -> fail(frame, error_text(reason))
    end
  end

  defp verified_actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine, :sub_agent] and is_binary(id) and id != "",
       do: {:ok, actor}

  defp verified_actor(_frame), do: {:error, :unauthenticated}

  defp options(params) do
    for key <- [:limit, :before], Map.has_key?(params, key), do: {key, Map.fetch!(params, key)}
  end

  defp error_text(:unauthenticated), do: "project_progress requires an authenticated MCP identity"
  defp error_text(:invalid_routine_id), do: "routine_id must be a nonempty configured routine id"

  defp error_text(:unknown_routine),
    do: "unknown project routine; use list_routines for valid ids"

  defp error_text(:invalid_options),
    do: "invalid project_progress options; load this tool's schema"

  defp error_text({:invalid_limit, _value}), do: "limit must be an integer from 1 to 20"

  defp error_text({:invalid_before, _value}),
    do: "before must be the opaque conversation.before cursor returned for this routine"

  defp error_text({:invalid_cursor, _cursor}),
    do: "invalid before cursor; use conversation.before from this routine's preceding page"

  defp error_text(reason) when is_binary(reason), do: reason

  defp error_text(_reason),
    do: "project progress is unavailable; refresh identity and retry the read"
end
