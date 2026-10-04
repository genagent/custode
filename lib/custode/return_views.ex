defmodule Custode.ReturnViews do
  @moduledoc "Current documents, historical production and context receipts remain distinct facts."
  import Ecto.Query, only: [from: 2]
  alias Custode.{ContextReceipts, Repo, ReturnNavigation, RunContextReceipts, SubjectDocuments}
  alias Snodo.Schema.Validator.Basic

  defmodule Feedback do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:request_id, :string, autogenerate: false}
    schema "document_feedback" do
      field(:root_id, :string)
      field(:path, :string)
      field(:fingerprint, :string)
      field(:record, :map)
    end
  end

  @doc "Parse the feedback form once for UI clients; shared validation and revision checks still apply."
  def feedback_form(actor, params) do
    with {first, ""} <- Integer.parse(params["start_line"] || ""),
         {last, ""} <- Integer.parse(params["end_line"] || "") do
      invoke(actor, Map.merge(params, %{"start_line" => first, "end_line" => last}))
    else
      _invalid -> {:error, "invalid_line_span"}
    end
  end

  def invoke(actor, params) do
    with :ok <- Basic.validate(params, input_schema()), do: perform(actor, params)
  end

  defp perform(actor, %{"action" => "outputs", "root_id" => root}) do
    with {:ok, listing} <-
           SubjectDocuments.invoke(actor, %{"action" => "browse", "root_id" => root}),
         {:ok, receipts} <- SubjectDocuments.outputs(actor, root) do
      outputs = for path <- listing["paths"], do: current_output(actor, root, path, receipts)

      {:ok,
       %{
         "outputs" => outputs,
         "reports" => "separate_agent_authored_evidence",
         "repository_state" => "unavailable_on_document_seam",
         "snapshot" => "per_file_not_atomic_root_snapshot"
       }}
    end
  end

  defp perform(actor, %{"action" => "detail", "root_id" => root, "path" => path}) do
    with {:ok, current} <-
           SubjectDocuments.invoke(actor, %{"action" => "read", "root_id" => root, "path" => path}),
         {:ok, receipts} <- SubjectDocuments.outputs(actor, root) do
      producers =
        Enum.filter(receipts, fn row ->
          (row["request"]["destination"] || row["request"]["path"]) == path
        end)

      {:ok,
       Map.merge(current, %{
         "production_receipts" =>
           Enum.map(Enum.take(producers, 10), &Map.drop(&1, ["request", "result"])),
         "disposition" => "document_not_acceptance",
         "opening_resumes_work" => false,
         "feedback" => feedback_history(root, path, current["revision"]),
         "navigation" => ReturnNavigation.read(actor, root, current["revision"], producers)
       })}
    end
  end

  defp perform(actor, %{"action" => "context", "receipt_id" => id}),
    do: ContextReceipts.read(actor, id)

  defp perform(actor, %{"action" => "contexts", "root_id" => root}),
    do: ContextReceipts.list(actor, root)

  defp perform(actor, %{"action" => "run_context", "receipt_id" => id}),
    do: RunContextReceipts.read(actor, id)

  defp perform(actor, %{"action" => "run_contexts", "agent_id" => id}) do
    with {:ok, records} <- RunContextReceipts.list(actor, id),
         do: {:ok, %{"receipts" => records, "opening_resumes_work" => false}}
  end

  defp perform(actor, %{"action" => "feedback"} = params) do
    required = ~w(root_id path expected_revision start_line end_line comment request_id)

    if Enum.all?(required, &Map.has_key?(params, &1)),
      do: feedback(actor, params),
      else: {:error, "feedback_arguments_required"}
  end

  defp perform(_actor, _params), do: {:error, "action_arguments_required"}

  defp feedback_history(root, path, revision) do
    Repo.all(
      from(row in Feedback,
        where: row.root_id == ^root and row.path == ^path,
        order_by: [desc: fragment("json_extract(?, '$.at')", row.record)],
        limit: 20
      )
    )
    |> Enum.map(fn row ->
      Map.put(row.record, "matches_current_revision", row.record["observed_revision"] == revision)
    end)
  end

  defp current_output(actor, root, path, receipts) do
    case SubjectDocuments.invoke(actor, %{"action" => "read", "root_id" => root, "path" => path}) do
      {:ok, current} ->
        current
        |> Map.delete("content")
        |> Map.put("production_receipts", production(receipts, path))
        |> Map.put("disposition", "document_not_acceptance")

      {:error, reason} ->
        %{"path" => path, "state" => "current_read_unavailable", "reason" => inspect(reason)}
    end
  end

  defp production(receipts, path) do
    receipts
    |> Enum.filter(fn row ->
      (row["request"]["destination"] || row["request"]["path"]) == path
    end)
    |> Enum.take(10)
    |> Enum.map(&Map.drop(&1, ["request", "result"]))
  end

  defp feedback(actor, params) do
    with {:ok, current} <-
           SubjectDocuments.invoke(
             actor,
             Map.merge(Map.take(params, ~w(root_id path)), %{"action" => "read"})
           ),
         true <-
           current["revision"] == params["expected_revision"] ||
             {:error, "revision_changed_reread_and_reanchor"},
         true <-
           (params["start_line"] <= params["end_line"] and
              params["end_line"] <= length(String.split(current["content"], "\n"))) ||
             {:error, "invalid_line_span"} do
      Repo.transaction(fn -> persist_feedback(actor, params, current["revision"]) end,
        mode: :immediate
      )
    end
  end

  defp persist_feedback(actor, params, revision) do
    fingerprint = SubjectDocuments.digest({actor, params})

    case Repo.get(Feedback, params["request_id"]) do
      nil ->
        record =
          params
          |> Map.put("actor", actor |> Jason.encode!() |> Jason.decode!())
          |> Map.put("observed_revision", revision)
          |> Map.put("at", DateTime.to_iso8601(DateTime.utc_now()))
          |> Map.put("effect", "comment_only_no_apply_no_approval")

        Repo.insert!(%Feedback{
          request_id: params["request_id"],
          root_id: params["root_id"],
          path: params["path"],
          fingerprint: fingerprint,
          record: record
        })

        record

      %Feedback{fingerprint: ^fingerprint} = row ->
        row.record

      _conflict ->
        Repo.rollback("idempotency_conflict")
    end
  end

  def input_schema do
    text = fn max -> %{"type" => "string", "minLength" => 1, "maxLength" => max} end

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ~w(outputs detail contexts context feedback run_contexts run_context)
        },
        "root_id" => text.(160),
        "agent_id" => text.(160),
        "path" => text.(200),
        "receipt_id" => text.(160),
        "request_id" => text.(160),
        "expected_revision" => text.(64),
        "comment" => text.(2000),
        "start_line" => %{"type" => "integer", "minimum" => 1},
        "end_line" => %{"type" => "integer", "minimum" => 1}
      }
    }
  end
end
