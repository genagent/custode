defmodule Custode.MCP.SubjectDocumentTools.Context do
  @moduledoc "Read current scoped subject documents or create explicitly granted new Markdown outputs; never apply or commit."
  use Custode.MCP.Tool, name: "subject_context"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  input_schema(Custode.SubjectDocuments.input_schema())

  @impl true
  def execute(params, frame) do
    with %{kind: kind, id: id} = actor <- frame.assigns[:custode_identity],
         true <- kind in [:operator, :routine, :sub_agent] and is_binary(id) and id != "",
         {:ok, result} <-
           Custode.SubjectDocuments.invoke(actor, params |> Jason.encode!() |> Jason.decode!()) do
      encoded = params |> Jason.encode!() |> Jason.decode!()

      case Custode.ContextReceipts.prepare(frame, encoded, result) do
        {:ok, text} -> {:reply, Snodo.Result.text(text), frame}
        :unavailable -> reply(frame, result)
      end
    else
      {:error, reason} -> fail(frame, "subject context refused: #{inspect(reason)}")
      _unauthenticated -> fail(frame, "subject context requires an authenticated identity")
    end
  end
end

defmodule Custode.MCP.ReturnViewTools.View do
  @moduledoc "Inspect current documents, historical tool text or submit revision-bound comments without resuming or approving work."
  use Custode.MCP.Tool, name: "return_context"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  input_schema(Custode.ReturnViews.input_schema())
  @impl true
  def execute(params, frame) do
    case Custode.ReturnViews.invoke(
           frame.assigns[:custode_identity],
           params |> Jason.encode!() |> Jason.decode!()
         ) do
      {:ok, result} -> reply(frame, result)
      {:error, reason} -> fail(frame, "return context refused: #{inspect(reason)}")
    end
  end
end

defmodule Custode.MCP.SubjectAssignmentTools.Configure do
  @moduledoc "Operator-only admission, inspection and revocation of exact helper subject assignments."
  use Custode.MCP.Tool, name: "subject_assignment"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  input_schema(Custode.SubjectAssignments.input_schema())

  @impl true
  def execute(params, frame) do
    case Custode.SubjectAssignments.invoke(
           frame.assigns[:custode_identity],
           params |> Jason.encode!() |> Jason.decode!()
         ) do
      {:ok, result} -> reply(frame, result)
      {:error, reason} -> fail(frame, "subject assignment refused: #{inspect(reason)}")
    end
  end
end
