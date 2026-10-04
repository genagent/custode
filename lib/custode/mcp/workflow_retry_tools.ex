defmodule Custode.MCP.WorkflowRetryTools.Read do
  @moduledoc "Explain unavailable workflow stage retry without enqueueing, cancelling or resuming."
  use Custode.MCP.Tool, name: "workflow_retry_status"
  alias Custode.Workflow.RetryStatus
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  input_schema(%{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["run_id"],
    "properties" => %{"run_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160}}
  })

  @impl true
  def execute(%{run_id: id}, frame) do
    with %{kind: kind, id: actor_id} = actor <- frame.assigns[:custode_identity],
         true <- kind in [:operator, :routine] and is_binary(actor_id) and actor_id != "",
         {:ok, status} <- RetryStatus.read(actor, id) do
      reply(frame, status)
    else
      {:error, reason} ->
        fail(frame, "workflow retry status refused: #{inspect(reason)}")

      _missing ->
        fail(frame, "workflow_retry_status requires a verified human or caretaker identity")
    end
  end
end
