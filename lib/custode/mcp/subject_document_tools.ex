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
      reply(frame, result)
    else
      {:error, reason} -> fail(frame, "subject context refused: #{inspect(reason)}")
      _unauthenticated -> fail(frame, "subject context requires an authenticated identity")
    end
  end
end
