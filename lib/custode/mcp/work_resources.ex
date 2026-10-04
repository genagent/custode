defmodule Custode.MCP.WorkResources do
  @moduledoc """
  Operator-only MCP resources for the work-first kernel.

  These resources are projections over authoritative Mission, WorkItem,
  Attempt, Artifact, Gate, OperationCall, and WorkEvent records. They do not
  accept writes and Attention is explicitly marked as derived.

  The fixed resources are:

    * `custode://missions`
    * `custode://work-items`
    * `custode://attention`
    * `custode://work-events`

  Detail and pagination use these RFC 6570 Level 1 templates:

    * `custode://missions/pages/{cursor}`
    * `custode://missions/{mission_id}`
    * `custode://missions/{mission_id}/work-items`
    * `custode://missions/{mission_id}/work-items/pages/{cursor}`
    * `custode://work-items/pages/{cursor}`
    * `custode://work-items/{work_item_id}`
    * `custode://work-items/{work_item_id}/attempt`
    * `custode://work-items/{work_item_id}/artifacts`
    * `custode://work-items/{work_item_id}/artifacts/pages/{cursor}`
    * `custode://work-items/{work_item_id}/events`
    * `custode://work-items/{work_item_id}/events/pages/{cursor}`
    * `custode://attention/pages/{cursor}`
    * `custode://work-events/pages/{cursor}`

  IDs and cursors are opaque path segments. Page payloads include both the
  opaque `next_cursor` and a directly readable `next_uri`.
  """

  alias Custode.{Attention, MCP, WorkReadModels}
  alias Custode.MCP.CallContext

  alias Snodo.Error

  @page_size 25

  @resources [
    %{
      uri: "custode://missions",
      name: "work_missions",
      title: "Missions",
      description: "Deterministically paginated Mission summaries."
    },
    %{
      uri: "custode://work-items",
      name: "work_items",
      title: "WorkItems",
      description: "Deterministically paginated WorkItem summaries."
    },
    %{
      uri: "custode://attention",
      name: "work_attention",
      title: "Attention",
      description: "Derived operator obligations linked to authoritative work state."
    },
    %{
      uri: "custode://work-events",
      name: "work_events",
      title: "WorkEvents",
      description: "Deterministically paginated append-only WorkEvent history."
    }
  ]

  @templates [
    %{
      uri: "custode://missions/pages/{cursor}",
      name: "work_missions_page",
      title: "Mission page",
      description: "Continue a Mission list using its opaque cursor."
    },
    %{
      uri: "custode://missions/{mission_id}",
      name: "work_mission_detail",
      title: "Mission detail",
      description: "Read one Mission by its stable opaque identifier."
    },
    %{
      uri: "custode://missions/{mission_id}/work-items",
      name: "mission_work_items",
      title: "Mission WorkItems",
      description: "List WorkItems belonging to one Mission."
    },
    %{
      uri: "custode://missions/{mission_id}/work-items/pages/{cursor}",
      name: "mission_work_items_page",
      title: "Mission WorkItem page",
      description: "Continue one Mission's WorkItem list using its opaque cursor."
    },
    %{
      uri: "custode://work-items/pages/{cursor}",
      name: "work_items_page",
      title: "WorkItem page",
      description: "Continue a WorkItem list using its opaque cursor."
    },
    %{
      uri: "custode://work-items/{work_item_id}",
      name: "work_item_detail",
      title: "WorkItem detail",
      description: "Read one WorkItem by its stable opaque identifier."
    },
    %{
      uri: "custode://work-items/{work_item_id}/attempt",
      name: "work_item_attempt",
      title: "Current Attempt",
      description: "Read the explicit active or newest logical Attempt for a WorkItem."
    },
    %{
      uri: "custode://work-items/{work_item_id}/artifacts",
      name: "work_item_artifacts",
      title: "WorkItem Artifacts",
      description: "List all Artifacts belonging to a WorkItem."
    },
    %{
      uri: "custode://work-items/{work_item_id}/artifacts/pages/{cursor}",
      name: "work_item_artifacts_page",
      title: "WorkItem Artifact page",
      description: "Continue one WorkItem's Artifact list using its opaque cursor."
    },
    %{
      uri: "custode://work-items/{work_item_id}/events",
      name: "work_item_events",
      title: "WorkItem events",
      description: "Read one WorkItem's append-only transition and process history."
    },
    %{
      uri: "custode://work-items/{work_item_id}/events/pages/{cursor}",
      name: "work_item_events_page",
      title: "WorkItem event page",
      description: "Continue one WorkItem's WorkEvent history using its opaque cursor."
    },
    %{
      uri: "custode://attention/pages/{cursor}",
      name: "work_attention_page",
      title: "Attention page",
      description: "Continue the derived Attention projection using its opaque cursor."
    },
    %{
      uri: "custode://work-events/pages/{cursor}",
      name: "work_events_page",
      title: "WorkEvent page",
      description: "Continue global append-only WorkEvent history using its opaque cursor."
    }
  ]

  @doc "Return the fixed resource definitions advertised to operator clients."
  @spec resource_definitions() :: [map()]
  def resource_definitions, do: @resources

  @doc "Return the resource-template definitions advertised to operator clients."
  @spec template_definitions() :: [map()]
  def template_definitions, do: @templates

  @doc "Read one registered work resource without changing authoritative state."
  @spec read(String.t(), CallContext.t()) ::
          {:reply, Snodo.Result.t(), CallContext.t()} | {:error, Error.t(), CallContext.t()}
  def read(uri, %CallContext{} = frame) when is_binary(uri) do
    if operator?(frame) do
      route(uri, frame)
    else
      not_found(uri, frame)
    end
  end

  defp route(uri, frame) do
    case URI.parse(uri) do
      %URI{
        scheme: "custode",
        userinfo: nil,
        port: nil,
        query: nil,
        fragment: nil,
        host: host,
        path: path
      }
      when is_binary(host) ->
        dispatch(host, path_segments(path), uri, frame)

      _invalid ->
        not_found(uri, frame)
    end
  end

  defp dispatch("missions", [], uri, frame), do: mission_page(uri, nil, frame)

  defp dispatch("missions", ["pages", cursor], uri, frame),
    do: mission_page(uri, cursor, frame)

  defp dispatch("missions", [mission_id], uri, frame),
    do: mission_detail(mission_id, uri, frame)

  defp dispatch("missions", [mission_id, "work-items"], uri, frame),
    do: work_item_page(uri, nil, mission_id, frame)

  defp dispatch(
         "missions",
         [mission_id, "work-items", "pages", cursor],
         uri,
         frame
       ),
       do: work_item_page(uri, cursor, mission_id, frame)

  defp dispatch("work-items", [], uri, frame), do: work_item_page(uri, nil, nil, frame)

  defp dispatch("work-items", ["pages", cursor], uri, frame),
    do: work_item_page(uri, cursor, nil, frame)

  defp dispatch("work-items", [work_item_id], uri, frame),
    do: work_item_detail(work_item_id, uri, frame)

  defp dispatch("work-items", [work_item_id, "attempt"], uri, frame),
    do: current_attempt(work_item_id, uri, frame)

  defp dispatch("work-items", [work_item_id, "artifacts"], uri, frame),
    do: artifact_page(work_item_id, uri, nil, frame)

  defp dispatch(
         "work-items",
         [work_item_id, "artifacts", "pages", cursor],
         uri,
         frame
       ),
       do: artifact_page(work_item_id, uri, cursor, frame)

  defp dispatch("work-items", [work_item_id, "events"], uri, frame),
    do: event_page(work_item_id, uri, nil, frame)

  defp dispatch(
         "work-items",
         [work_item_id, "events", "pages", cursor],
         uri,
         frame
       ),
       do: event_page(work_item_id, uri, cursor, frame)

  defp dispatch("attention", [], uri, frame), do: attention_page(uri, nil, frame)

  defp dispatch("attention", ["pages", cursor], uri, frame),
    do: attention_page(uri, cursor, frame)

  defp dispatch("work-events", [], uri, frame), do: event_page(nil, uri, nil, frame)

  defp dispatch("work-events", ["pages", cursor], uri, frame),
    do: event_page(nil, uri, cursor, frame)

  defp dispatch(_host, _segments, uri, frame), do: not_found(uri, frame)

  defp mission_page(uri, cursor, frame) do
    case WorkReadModels.list_missions(limit: @page_size, after: cursor) do
      {:ok, page} ->
        next_uri = next_uri(page, &"custode://missions/pages/#{segment(&1)}")
        reply(page_payload("custode.mission.list.v1", page, uri, next_uri), frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp mission_detail(mission_id, uri, frame) do
    case WorkReadModels.get_mission(mission_id) do
      {:ok, mission} ->
        links = %{
          self: uri,
          work_items: "custode://missions/#{segment(mission_id)}/work-items"
        }

        reply(Map.put(mission, :links, links), frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp work_item_page(uri, cursor, mission_id, frame) do
    with :ok <- ensure_mission(mission_id),
         {:ok, page} <-
           WorkReadModels.list_work_items(
             limit: @page_size,
             after: cursor,
             mission_id: mission_id
           ) do
      next_uri =
        next_uri(page, fn next_cursor ->
          work_item_page_uri(mission_id, next_cursor)
        end)

      reply(page_payload("custode.work_item.list.v1", page, uri, next_uri), frame)
    else
      {:error, reason} -> domain_error(reason, uri, frame)
    end
  end

  defp work_item_detail(work_item_id, uri, frame) do
    case WorkReadModels.get_work_item(work_item_id) do
      {:ok, work_item} ->
        links = %{
          self: uri,
          mission: "custode://missions/#{segment(work_item.mission_id)}",
          current_attempt: "custode://work-items/#{segment(work_item_id)}/attempt",
          artifacts: "custode://work-items/#{segment(work_item_id)}/artifacts",
          events: "custode://work-items/#{segment(work_item_id)}/events"
        }

        reply(Map.put(work_item, :links, links), frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp current_attempt(work_item_id, uri, frame) do
    case WorkReadModels.get_work_item(work_item_id) do
      {:ok, work_item} ->
        payload = %{
          contract: "custode.work_item.current_attempt.v1",
          mission_id: work_item.mission_id,
          work_item_id: work_item.work_item_id,
          attempt: work_item.current_attempt,
          links: %{
            self: uri,
            mission: "custode://missions/#{segment(work_item.mission_id)}",
            work_item: "custode://work-items/#{segment(work_item_id)}"
          }
        }

        reply(payload, frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp artifact_page(work_item_id, uri, cursor, frame) do
    case WorkReadModels.list_work_item_artifacts(work_item_id,
           limit: @page_size,
           after: cursor
         ) do
      {:ok, page} ->
        next_uri =
          next_uri(
            page,
            &"custode://work-items/#{segment(work_item_id)}/artifacts/pages/#{segment(&1)}"
          )

        reply(page_payload("custode.artifact.list.v1", page, uri, next_uri), frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp event_page(work_item_id, uri, cursor, frame) do
    case WorkReadModels.list_work_events(
           limit: @page_size,
           after: cursor,
           work_item_id: work_item_id
         ) do
      {:ok, page} ->
        next_uri = next_uri(page, &event_page_uri(work_item_id, &1))
        reply(page_payload("custode.work_event.list.v1", page, uri, next_uri), frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp attention_page(uri, cursor, frame) do
    case Attention.list(limit: @page_size, after: cursor) do
      {:ok, page} ->
        page = Map.update!(page, :items, &Enum.map(&1, fn item -> attention_item(item) end))
        next_uri = next_uri(page, &"custode://attention/pages/#{segment(&1)}")

        payload =
          "custode.attention.list.v1"
          |> page_payload(page, uri, next_uri)
          |> Map.put(:projection, %{derived: true, independently_mutable: false})

        reply(payload, frame)

      {:error, reason} ->
        domain_error(reason, uri, frame)
    end
  end

  defp page_payload(contract, page, uri, next_uri) do
    %{
      contract: contract,
      items: page.items,
      page: Map.put(page.page, :next_uri, next_uri),
      links: %{self: uri, next: next_uri}
    }
  end

  defp attention_item(item) do
    subject_uri = subject_uri(item.subject)
    relationship = source_relationship(item.source)

    item
    |> Map.update!(:source, fn source ->
      Map.merge(source, %{resource_uri: subject_uri, relationship: relationship})
    end)
    |> Map.put(:links, %{
      subject: subject_uri,
      authoritative_source: subject_uri
    })
  end

  defp subject_uri(%{kind: "mission", id: mission_id}),
    do: "custode://missions/#{segment(mission_id)}"

  defp subject_uri(%{kind: "work_item", id: work_item_id}),
    do: "custode://work-items/#{segment(work_item_id)}"

  defp subject_uri(_subject), do: nil

  defp source_relationship(%{kind: "work_gate"}), do: "open_gates"
  defp source_relationship(%{kind: "operation_call"}), do: "relationships.operation_call_ids"
  defp source_relationship(%{kind: "work_item"}), do: "self"
  defp source_relationship(_source), do: nil

  defp ensure_mission(nil), do: :ok

  defp ensure_mission(mission_id) do
    case WorkReadModels.get_mission(mission_id) do
      {:ok, _mission} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_uri(%{page: %{has_more: true, next_cursor: cursor}}, builder)
       when is_binary(cursor),
       do: builder.(cursor)

  defp next_uri(_page, _builder), do: nil

  defp work_item_page_uri(nil, cursor),
    do: "custode://work-items/pages/#{segment(cursor)}"

  defp work_item_page_uri(mission_id, cursor),
    do: "custode://missions/#{segment(mission_id)}/work-items/pages/#{segment(cursor)}"

  defp event_page_uri(nil, cursor),
    do: "custode://work-events/pages/#{segment(cursor)}"

  defp event_page_uri(work_item_id, cursor),
    do: "custode://work-items/#{segment(work_item_id)}/events/pages/#{segment(cursor)}"

  defp path_segments(nil), do: []

  defp path_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&URI.decode/1)
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp operator?(frame), do: match?(%{kind: :operator}, MCP.caller(frame))

  defp reply(payload, frame) do
    {:reply, Snodo.Result.text(JSON.encode!(payload)), frame}
  end

  defp domain_error({kind, _id}, uri, frame)
       when kind in [:unknown_mission, :unknown_work_item],
       do: not_found(uri, frame)

  defp domain_error({:invalid_cursor, _cursor} = reason, uri, frame),
    do: invalid_params(reason, uri, frame)

  defp domain_error(reason, uri, frame), do: invalid_params(reason, uri, frame)

  defp invalid_params(reason, uri, frame) do
    error = Error.invalid_params("Invalid params", %{"uri" => uri, "reason" => inspect(reason)})
    {:error, error, frame}
  end

  defp not_found(uri, frame) do
    error = %Error{
      code: -32_002,
      message: "Resource not found",
      kind: :protocol,
      data: %{"uri" => uri}
    }

    {:error, error, frame}
  end
end
