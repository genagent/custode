defmodule Custode.ReturnNavigation do
  @moduledoc "Scoped return links separate current named documents from historical publication epochs."
  alias Custode.{HelperRecords, SubjectDocuments}

  def read(actor, root, current_revision, receipts) do
    projection = %{
      "schema_version" => "custode.return_navigation.v1",
      "current_plan" => plan(actor, root),
      "productions" =>
        receipts
        |> Enum.filter(&(&1["status"] == "created"))
        |> Enum.take(3)
        |> Enum.map(&production(actor, current_revision, &1)),
      "consistency" => "independent_current_reads_and_historical_records",
      "opening_resumes_work" => false,
      "native_delivery_binding" => "unknown"
    }

    if byte_size(Jason.encode!(projection)) <= 64_000 do
      projection
    else
      Map.merge(projection, %{"productions" => [], "availability" => "navigation_byte_limit"})
    end
  end

  defp plan(actor, root) do
    with {:ok, roots} <- SubjectDocuments.invoke(actor, %{"action" => "roots"}),
         %{"current_plan" => path} when is_binary(path) <-
           Enum.find(roots["roots"], &(&1["root_id"] == root)),
         {:ok, current} <-
           SubjectDocuments.invoke(actor, %{"action" => "read", "root_id" => root, "path" => path}) do
      current
      |> Map.take(~w(root_id path revision bytes source))
      |> Map.put("availability", "current_named_document")
      |> Map.put("link", document_link(root, path))
      |> Map.put("execution_plan_binding", "not_inferred")
    else
      {:error, reason} ->
        %{"availability" => "current_plan_read_unavailable", "reason" => inspect(reason)}

      _ ->
        %{"availability" => "no_granted_named_plan"}
    end
  end

  defp production(actor, current_revision, record) do
    producer = record["producer"] || %{}
    published = record["result"] || %{}
    revision = published["revision"] || get_in(published, ["proposal", "revision"])

    %{
      "request_id" => record["request_id"],
      "published_at" => record["at"],
      "published_revision" => revision,
      "matches_current_revision" => revision == current_revision,
      "source" => "immutable_publication_receipt",
      "receipt_reference" => %{
        "tool" => "subject_context",
        "arguments" => %{
          "action" => "receipt",
          "root_id" => published["root_id"],
          "request_id" => record["request_id"]
        }
      },
      "recorded_owner" => owner(producer),
      "helper" => helper(actor, producer["helper_epoch"]),
      "execution_observation" => "inspect_original_publication_receipt_not_native_delivery"
    }
  end

  defp owner(%{"identity" => %{"kind" => "routine", "id" => id}}), do: owner_link(id)

  defp owner(%{"identity" => %{"kind" => "sub_agent"}, "parent" => id}) when is_binary(id),
    do: owner_link(id)

  defp owner(_producer), do: %{"availability" => "recorded_owner_unavailable"}

  defp owner_link(id),
    do: %{
      "id" => id,
      "link" => "/agents/" <> URI.encode(id, &URI.char_unreserved?/1) <> "/conversation",
      "source" => "historical_recorded_owner",
      "current_execution" => "not_read_or_relabelled"
    }

  defp helper(_actor, nil), do: %{"availability" => "no_captured_helper_epoch"}

  defp helper(actor, reference) do
    case HelperRecords.read_epoch(actor, reference) do
      {:ok, record} ->
        %{
          "availability" => "retained_spawn_epoch",
          "reference" => reference,
          "record" => record |> Jason.encode!() |> Jason.decode!(),
          "native_publication_run_binding" => "unknown"
        }

      {:error, reason} ->
        %{"availability" => reason, "reference" => reference}
    end
  end

  def document_link(root, path),
    do: "/subjects/" <> URI.encode_www_form(root) <> "?file=" <> URI.encode_www_form(path)
end
