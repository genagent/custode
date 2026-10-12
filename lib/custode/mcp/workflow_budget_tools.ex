defmodule Custode.MCP.WorkflowBudgetTools do
  @moduledoc false

  alias Custode.MCP.Tools
  alias Custode.Operator.Actions

  @schema_version "custode.workflow_budget_resume.v1"

  @refusals [
    :human_identity_required,
    :pause_required,
    :no_such_run,
    :stale_pause,
    :not_paused,
    :outer_transaction_unsupported
  ]

  def input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["run_id", "pause_id"],
      "properties" => %{
        "run_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024},
        "pause_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160}
      }
    }
  end

  def output do
    properties = %{
      "schema_version" => %{"type" => "string", "enum" => [@schema_version]},
      "run_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024},
      "pause_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160},
      "decision" => %{"type" => "string", "enum" => ["resumed"]},
      "previous_budget_usd" => %{"type" => ["number", "null"]},
      "budget_usd" => %{"type" => ["number", "null"]},
      "status" => %{"type" => "string", "enum" => ["running"]}
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => Map.keys(properties),
      "properties" => properties
    }
  end

  def execute(params, frame) do
    case frame.assigns[:custode_identity] do
      %{kind: :operator, id: id} = actor when is_binary(id) and id != "" ->
        case Actions.resume_run(params.run_id, params.pause_id, actor: actor, via: :mcp) do
          {:ok, receipt} -> success(frame, receipt)
          {:error, reason} -> refusal(frame, reason)
        end

      _missing_or_nonhuman ->
        refusal(frame, :human_identity_required)
    end
  end

  # Only the receipt's known fields leave the server, so a core change cannot
  # leak a private field through this tool.
  defp success(frame, receipt) do
    result = %{
      "schema_version" => receipt.schema_version,
      "run_id" => receipt.run_id,
      "pause_id" => receipt.pause_id,
      "decision" => receipt.decision,
      "previous_budget_usd" => receipt.previous_budget_usd,
      "budget_usd" => receipt.budget_usd,
      "status" => receipt.status
    }

    {:reply, Snodo.Result.structured(result), frame}
  end

  defp refusal(frame, reason) do
    code =
      case reason do
        code when code in @refusals -> Atom.to_string(code)
        # Authority.human answers a human-readable string for a refused actor.
        message when is_binary(message) -> "human_identity_required"
        _private_failure -> "admission_failed"
      end

    Tools.fail(frame, "workflow budget resume refused: " <> code)
  end
end

defmodule Custode.MCP.WorkflowBudgetTools.Resume do
  @moduledoc "Raise the budget rail of one exact workflow budget pause and resume its run as the verified human. Success is admission; work may continue asynchronously and completion is not guaranteed. Repeating the same pause returns the original receipt and never raises the rail twice."
  use Custode.MCP.Tool, name: "workflow_budget_resume", strict_arguments: true
  alias Custode.MCP.WorkflowBudgetTools

  input_schema(WorkflowBudgetTools.input())
  output_schema(WorkflowBudgetTools.output())

  @impl true
  def execute(params, frame), do: WorkflowBudgetTools.execute(params, frame)
end
