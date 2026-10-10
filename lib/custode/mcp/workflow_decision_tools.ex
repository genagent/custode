defmodule Custode.MCP.WorkflowDecisionTools do
  @moduledoc false

  alias Custode.MCP.Tools
  alias Custode.Operator.Actions

  def input(decision) do
    properties = %{
      "proposal_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160}
    }

    properties =
      if decision == :reject,
        do: Map.put(properties, "reason", %{"type" => "string", "maxLength" => 2_000}),
        else: properties

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["proposal_id"],
      "properties" => properties
    }
  end

  def output(decision) do
    properties = %{
      "proposal_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 160},
      "decision" => %{
        "type" => "string",
        "enum" => [if(decision == :approve, do: "approved", else: "rejected")]
      }
    }

    properties =
      if decision == :approve do
        Map.merge(properties, %{
          "run_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024},
          "status" => %{"type" => "string", "enum" => ~w(running budget_paused complete failed)},
          "budget_usd" => %{"type" => ["number", "null"]}
        })
      else
        properties
      end

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => Map.keys(properties),
      "properties" => properties
    }
  end

  def execute(decision, params, frame) do
    case frame.assigns[:custode_identity] do
      %{kind: :operator, id: id} = actor when is_binary(id) and id != "" ->
        operation(decision, params, [actor: actor, via: :mcp], frame)

      _missing_or_nonhuman ->
        refusal(frame, :human_identity_required)
    end
  end

  defp operation(:approve, params, opts, frame) do
    case Actions.approve_launch(params.proposal_id, opts) do
      {:ok, run} ->
        success(frame, %{
          "proposal_id" => params.proposal_id,
          "decision" => "approved",
          "run_id" => run.run_id,
          "status" => run.status,
          "budget_usd" => run.budget_usd
        })

      {:error, reason} ->
        refusal(frame, reason)
    end
  end

  defp operation(:reject, params, opts, frame) do
    case Actions.reject_launch(params.proposal_id, Map.get(params, :reason), opts) do
      :ok -> success(frame, %{"proposal_id" => params.proposal_id, "decision" => "rejected"})
      {:error, reason} -> refusal(frame, reason)
    end
  end

  defp success(frame, result), do: {:reply, Snodo.Result.structured(result), frame}

  defp refusal(frame, reason) do
    code =
      case reason do
        code
        when code in [
               :human_identity_required,
               :no_such_proposal,
               :expired_proposal,
               :decision_conflict,
               :retained_run_missing,
               :unknown_workflow,
               :outer_transaction_unsupported
             ] ->
          Atom.to_string(code)

        _private_failure ->
          "admission_failed"
      end

    Tools.fail(frame, "workflow launch decision refused: " <> code)
  end
end

defmodule Custode.MCP.WorkflowDecisionTools.Approve do
  @moduledoc "Approve an existing workflow proposal as the verified human. Success is admission; work may start asynchronously and completion is not guaranteed. Repeating approval does not restart dispatched work."
  use Custode.MCP.Tool, name: "workflow_launch_approve", strict_arguments: true
  alias Custode.MCP.WorkflowDecisionTools

  input_schema(WorkflowDecisionTools.input(:approve))
  output_schema(WorkflowDecisionTools.output(:approve))

  @impl true
  def execute(params, frame),
    do: WorkflowDecisionTools.execute(:approve, params, frame)
end

defmodule Custode.MCP.WorkflowDecisionTools.Reject do
  @moduledoc "Reject an existing workflow proposal as the verified human, retaining its first decision and optional reason."
  use Custode.MCP.Tool, name: "workflow_launch_reject", strict_arguments: true
  alias Custode.MCP.WorkflowDecisionTools

  input_schema(WorkflowDecisionTools.input(:reject))
  output_schema(WorkflowDecisionTools.output(:reject))

  @impl true
  def execute(params, frame),
    do: WorkflowDecisionTools.execute(:reject, params, frame)
end
