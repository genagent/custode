defmodule Custode.ReturnNavigation do
  @moduledoc "Scoped return links separate current named documents from historical publication epochs."
  alias Custode.{HelperRecords, RunContextReceipts, SubjectDocuments}

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
    provenance = provenance(producer, published)

    %{
      "request_id" => record["request_id"],
      "recorded_at" => record["at"],
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
      "recorded_owner" => recorded_owner(provenance),
      "helper" => recorded_helper(actor, provenance),
      "producing_context" => producing_context(actor, provenance),
      "execution_observation" => "inspect_original_publication_receipt_not_native_delivery"
    }
  end

  defp provenance(%{"assignment_execution" => binding} = producer, published) do
    with %{"kind" => "sub_agent", "id" => helper, "subject_launch_id" => launch} <-
           producer["identity"],
         %{
           "parent" => parent,
           "launch_id" => ^launch,
           "root_id" => root,
           "helper_epoch" => epoch,
           "execution" => execution
         } <- binding,
         true <- Enum.all?([parent, helper, launch, root], &(is_binary(&1) and &1 != "")),
         true <- root == published["root_id"],
         %{
           "agent_id" => ^helper,
           "parent" => ^parent,
           "record_id" => record_id,
           "spawned_at" => spawned
         } <- epoch,
         true <- is_integer(record_id) and record_id > 0 and is_binary(spawned),
         %{"agent_id" => ^helper} <- execution,
         true <- consistent?(producer, "parent", parent),
         true <- consistent?(producer, "helper_epoch", epoch) do
      {:admitted, parent, epoch, binding}
    else
      _unavailable -> :conflicting_provenance
    end
  end

  defp provenance(producer, _published), do: {:legacy, producer}

  defp consistent?(producer, key, expected),
    do: not Map.has_key?(producer, key) or producer[key] == expected

  defp recorded_owner({:admitted, parent, _epoch, _binding}), do: owner_link(parent)

  defp recorded_owner({:legacy, %{"identity" => %{"kind" => "routine", "id" => id}}}),
    do: owner_link(id)

  defp recorded_owner({:legacy, %{"identity" => %{"kind" => "sub_agent"}, "parent" => id}})
       when is_binary(id), do: owner_link(id)

  defp recorded_owner(_unavailable), do: %{"availability" => "recorded_owner_unavailable"}

  defp recorded_helper(actor, {:admitted, _parent, epoch, _binding}), do: helper(actor, epoch)
  defp recorded_helper(actor, {:legacy, producer}), do: helper(actor, producer["helper_epoch"])
  defp recorded_helper(_actor, _unavailable), do: %{"availability" => "conflicting_provenance"}

  defp producing_context(actor, {:admitted, _parent, _epoch, binding}),
    do: RunContextReceipts.assignment_reference(actor, binding)

  defp producing_context(_actor, _unavailable),
    do: %{"availability" => "exact_assignment_context_unavailable"}

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
