defmodule Custode.WorkReadModels do
  @moduledoc """
  Stable, transport-neutral projections of Mission and WorkItem truth.

  These read models are computed from the authoritative kernel rows on every
  call. They are not stored, cached, or accepted as write input, so rebuilding
  a projection cannot create another lifecycle authority.

  ## Contracts

  `list_missions/1` and `list_work_items/1` return bounded summary contracts:

      %{
        items: [%{contract: "custode.mission.summary.v1" | "custode.work_item.summary.v1"}],
        page: %{
          limit: pos_integer(),
          has_more: boolean(),
          next_cursor: String.t() | nil,
          order: [String.t()]
        }
      }

  Detail reads use `custode.mission.detail.v1` and
  `custode.work_item.detail.v1`. Artifact and WorkEvent pages use
  `custode.artifact.v1` and `custode.work_event.v1`. WorkItem state and
  workflow phase remain separate fields. Detail relationships retain the
  stable identifiers needed to traverse Attempts, OperationCalls, Gates,
  Artifacts, and WorkEvents.

  A WorkItem's explicit active Attempt is current while it exists. Otherwise
  the newest logical Attempt remains current for operator continuity.
  `current_attempt.active` distinguishes those cases. Relevant Artifacts are
  the WorkItem's unexpired Artifacts.

  Cursors are opaque keyset cursors. Missions, WorkItems, Artifacts, and
  WorkEvents are ordered by insertion time and then their stable public
  identifier, both ascending.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Attempt,
    LegacyRoutineMissionMapping,
    Mission,
    MissionTarget,
    OperationCall,
    Repo,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems
  }

  @default_limit 25
  @max_limit 100
  @mission_order ["inserted_at:asc", "mission_id:asc"]
  @work_item_order ["inserted_at:asc", "work_item_id:asc"]
  @artifact_order ["inserted_at:asc", "artifact_id:asc"]
  @work_event_order ["inserted_at:asc", "event_id:asc"]
  @states ~w(proposed ready active waiting blocked completed cancelled)
  @transition_kinds ~w(work_item.created work_item.transitioned work_item.reopened)
  @legacy_projected_fields ~w(
    key
    purpose
    lifecycle
    targets
    policy_ref
    budget_ref
    context_ref
    retention_seconds
    metadata
  )

  @type page :: %{
          items: [map()],
          page: %{
            limit: pos_integer(),
            has_more: boolean(),
            next_cursor: String.t() | nil,
            order: [String.t()]
          }
        }

  @doc "List Mission summaries using a deterministic opaque cursor."
  @spec list_missions(keyword() | map()) :: {:ok, page()} | {:error, term()}
  def list_missions(options \\ []) do
    with {:ok, options} <- options(options, limit: @default_limit, after: nil),
         {:ok, cursor} <- decode_cursor(options[:after], "mission", nil),
         :ok <- validate_limit(options[:limit]) do
      fetch_limit = options[:limit] + 1

      query =
        from(mission in Mission,
          order_by: [asc: mission.inserted_at, asc: mission.mission_id],
          limit: ^fetch_limit
        )
        |> after_mission(cursor)

      rows = Repo.all(query)
      {missions, page} = page(rows, options[:limit], "mission", nil, @mission_order)
      context = load_mission_context(missions)

      {:ok, %{items: Enum.map(missions, &mission_summary(&1, context)), page: page}}
    end
  end

  @doc "Read one complete Mission projection."
  @spec get_mission(String.t()) :: {:ok, map()} | {:error, term()}
  def get_mission(mission_id) when is_binary(mission_id) do
    case Repo.get_by(Mission, mission_id: mission_id) do
      nil ->
        {:error, {:unknown_mission, mission_id}}

      mission ->
        context = load_mission_context([mission])
        {:ok, mission_detail(mission, context)}
    end
  end

  @doc """
  Recompute one Mission projection from authoritative rows.

  This explicit alias is useful to reconcilers and tests that need to state
  the rebuild boundary rather than imply a cached read.
  """
  @spec rebuild_mission(String.t()) :: {:ok, map()} | {:error, term()}
  def rebuild_mission(mission_id), do: get_mission(mission_id)

  @doc """
  List WorkItem summaries using a deterministic opaque cursor.

  Pass `mission_id: id` to scope the page to one Mission. A cursor is bound to
  that scope and is rejected if reused for a different Mission.
  """
  @spec list_work_items(keyword() | map()) :: {:ok, page()} | {:error, term()}
  def list_work_items(options \\ []) do
    with {:ok, options} <-
           options(options, limit: @default_limit, after: nil, mission_id: nil),
         :ok <- validate_mission_scope(options[:mission_id]),
         {:ok, cursor} <-
           decode_cursor(options[:after], "work_item", options[:mission_id]),
         :ok <- validate_limit(options[:limit]) do
      fetch_limit = options[:limit] + 1

      query =
        from(work_item in WorkItem,
          order_by: [asc: work_item.inserted_at, asc: work_item.work_item_id],
          limit: ^fetch_limit
        )
        |> for_mission(options[:mission_id])
        |> after_work_item(cursor)

      rows =
        query
        |> Repo.all()
        |> Repo.preload([:mission, :parent])

      {work_items, page} =
        page(
          rows,
          options[:limit],
          "work_item",
          options[:mission_id],
          @work_item_order
        )

      context = load_work_item_context(work_items)

      {:ok, %{items: Enum.map(work_items, &work_item_summary(&1, context)), page: page}}
    end
  end

  @doc "Read one complete WorkItem projection."
  @spec get_work_item(String.t()) :: {:ok, map()} | {:error, term()}
  def get_work_item(work_item_id) when is_binary(work_item_id) do
    case WorkItem
         |> Repo.get_by(work_item_id: work_item_id)
         |> preload_work_item() do
      nil ->
        {:error, {:unknown_work_item, work_item_id}}

      work_item ->
        context = load_work_item_context([work_item])
        {:ok, work_item_detail(work_item, context)}
    end
  end

  @doc "Recompute one WorkItem projection from authoritative rows and events."
  @spec rebuild_work_item(String.t()) :: {:ok, map()} | {:error, term()}
  def rebuild_work_item(work_item_id), do: get_work_item(work_item_id)

  @doc "List all Artifacts for one WorkItem using a scope-bound opaque cursor."
  @spec list_work_item_artifacts(String.t(), keyword() | map()) ::
          {:ok, page()} | {:error, term()}
  def list_work_item_artifacts(work_item_id, options \\ [])

  def list_work_item_artifacts(work_item_id, options)
      when is_binary(work_item_id) and work_item_id != "" do
    with {:ok, options} <- options(options, limit: @default_limit, after: nil),
         :ok <- validate_limit(options[:limit]),
         {:ok, work_item} <- fetch_work_item(work_item_id),
         {:ok, cursor} <- decode_cursor(options[:after], "artifact", work_item_id) do
      fetch_limit = options[:limit] + 1

      rows =
        from(artifact in Artifact,
          where: artifact.work_item_id == ^work_item.id,
          order_by: [asc: artifact.inserted_at, asc: artifact.artifact_id],
          limit: ^fetch_limit
        )
        |> after_artifact(cursor)
        |> Repo.all()
        |> Repo.preload([:producer_attempt, :work_item, :mission])

      {artifacts, page} =
        page(rows, options[:limit], "artifact", work_item_id, @artifact_order)

      {:ok, %{items: Enum.map(artifacts, &artifact_contract/1), page: page}}
    end
  end

  def list_work_item_artifacts(work_item_id, _options),
    do: {:error, {:invalid_work_item_id, work_item_id}}

  @doc """
  List append-only WorkEvents using a deterministic opaque cursor.

  Pass `work_item_id: id` for one WorkItem's complete event history. The
  cursor is bound to that scope and cannot be reused for a different WorkItem.
  """
  @spec list_work_events(keyword() | map()) :: {:ok, page()} | {:error, term()}
  def list_work_events(options \\ []) do
    with {:ok, options} <-
           options(options, limit: @default_limit, after: nil, work_item_id: nil),
         :ok <- validate_work_item_scope(options[:work_item_id]),
         :ok <- ensure_work_item_exists(options[:work_item_id]),
         {:ok, cursor} <-
           decode_cursor(options[:after], "work_event", options[:work_item_id]),
         :ok <- validate_limit(options[:limit]) do
      fetch_limit = options[:limit] + 1

      rows =
        from(event in WorkEvent,
          order_by: [asc: event.inserted_at, asc: event.event_id],
          limit: ^fetch_limit
        )
        |> for_work_item(options[:work_item_id])
        |> after_work_event(cursor)
        |> Repo.all()
        |> Repo.preload([:mission, :work_item])

      {events, page} =
        page(
          rows,
          options[:limit],
          "work_event",
          options[:work_item_id],
          @work_event_order
        )

      {:ok, %{items: Enum.map(events, &work_event_contract/1), page: page}}
    end
  end

  defp mission_summary(mission, context) do
    targets = rows(context.targets, mission.id)
    work_items = rows(context.work_items, mission.id)
    mappings = rows(context.mappings, mission.id)
    transitions = rows(context.events, mission.id) |> transition_events()

    %{
      contract: "custode.mission.summary.v1",
      mission_id: mission.mission_id,
      key: mission.key,
      purpose: mission.purpose,
      lifecycle: mission.lifecycle,
      status: mission.status,
      targets: Enum.map(targets, &target/1),
      policy_ref: mission.policy_ref,
      budget_ref: mission.budget_ref,
      context_ref: mission.context_ref,
      work: %{
        total: length(work_items),
        by_state: counts_by_state(work_items)
      },
      last_transition: transitions |> List.last() |> event(),
      compatibility: mission_compatibility(mappings),
      archived_at: iso8601(mission.archived_at),
      inserted_at: iso8601(mission.inserted_at),
      updated_at: iso8601(mission.updated_at)
    }
  end

  defp mission_detail(mission, context) do
    work_items = rows(context.work_items, mission.id)
    work_item_ids = Enum.map(work_items, & &1.id)
    events = rows(context.events, mission.id)
    gates = rows(context.gates, mission.id)
    artifacts = rows(context.artifacts, mission.id)
    calls = rows(context.calls, mission.mission_id)

    mission
    |> mission_summary(context)
    |> Map.put(:contract, "custode.mission.detail.v1")
    |> Map.put(:retention_seconds, mission.retention_seconds)
    |> Map.put(:metadata, mission.metadata)
    |> Map.put(:relationships, %{
      work_item_ids: Enum.map(work_items, & &1.work_item_id),
      attempt_ids:
        context.attempts
        |> rows_for_many(work_item_ids)
        |> Enum.map(& &1.attempt_id),
      operation_call_ids: operation_call_ids(work_items, events, gates, calls),
      gate_ids: Enum.map(gates, & &1.gate_id),
      artifact_ids: Enum.map(artifacts, & &1.artifact_id),
      event_ids: Enum.map(events, & &1.event_id)
    })
  end

  defp work_item_summary(work_item, context) do
    attempts = rows(context.attempts, work_item.id)
    gates = rows(context.gates, work_item.id)
    artifacts = rows(context.artifacts, work_item.id) |> relevant_artifacts()
    events = rows(context.events, work_item.id)
    mappings = rows(context.mappings, work_item.mission_id)
    current_attempt = current_attempt(work_item, attempts)

    %{
      contract: "custode.work_item.summary.v1",
      work_item_id: work_item.work_item_id,
      mission_id: work_item.mission.mission_id,
      parent_work_item_id: work_item.parent && work_item.parent.work_item_id,
      target: work_target(work_item, rows(context.targets, work_item.mission_id)),
      kind: work_item.kind,
      workflow_version: work_item.workflow_version,
      state: work_item.state,
      phase: work_item.phase,
      version: work_item.version,
      priority: work_item.priority,
      current_attempt: attempt_summary(current_attempt, work_item),
      open_gates: gates |> Enum.filter(&(&1.status == "open")) |> Enum.map(&gate_summary/1),
      relevant_artifacts: Enum.map(artifacts, &artifact_summary/1),
      last_transition: events |> transition_events() |> List.last() |> event(),
      compatibility: work_item_compatibility(mappings),
      inserted_at: iso8601(work_item.inserted_at),
      updated_at: iso8601(work_item.updated_at)
    }
  end

  defp work_item_detail(work_item, context) do
    attempts = rows(context.attempts, work_item.id)
    gates = rows(context.gates, work_item.id)
    open_gates = Enum.filter(gates, &(&1.status == "open"))
    artifacts = rows(context.artifacts, work_item.id)
    relevant = relevant_artifacts(artifacts)
    events = rows(context.events, work_item.id)
    calls = rows(context.calls, work_item.work_item_id)
    current_attempt = current_attempt(work_item, attempts)

    work_item
    |> work_item_summary(context)
    |> Map.put(:contract, "custode.work_item.detail.v1")
    |> Map.merge(%{
      objective: work_item.objective,
      acceptance_criteria: work_item.acceptance_criteria,
      policy_ref: work_item.policy_ref,
      source: work_item.source,
      external_key: work_item.external_key,
      active_attempt_id: work_item.active_attempt_id,
      active_operation_call_id: work_item.active_operation_call_id,
      waiting_condition: work_item.waiting_condition,
      blocked_reason: work_item.blocked_reason,
      outcome: work_item.outcome,
      completed_at: iso8601(work_item.completed_at),
      cancelled_at: iso8601(work_item.cancelled_at),
      current_attempt: attempt_detail(current_attempt, work_item),
      open_gates: Enum.map(open_gates, &gate_detail/1),
      relevant_artifacts: Enum.map(relevant, &artifact_detail/1),
      relationships: %{
        mission_id: work_item.mission.mission_id,
        parent_work_item_id: work_item.parent && work_item.parent.work_item_id,
        attempt_ids: Enum.map(attempts, & &1.attempt_id),
        operation_call_ids: operation_call_ids([work_item], events, gates, calls),
        gate_ids: Enum.map(gates, & &1.gate_id),
        artifact_ids: Enum.map(artifacts, & &1.artifact_id),
        event_ids: Enum.map(events, & &1.event_id)
      }
    })
  end

  defp load_mission_context([]), do: empty_context()

  defp load_mission_context(missions) do
    mission_ids = Enum.map(missions, & &1.id)
    public_mission_ids = Enum.map(missions, & &1.mission_id)

    targets =
      Repo.all(
        from(target in MissionTarget,
          where: target.mission_id in ^mission_ids,
          order_by: [
            asc: target.mission_id,
            asc: target.kind,
            asc: target.external_id,
            asc: target.id
          ]
        )
      )

    mappings =
      Repo.all(
        from(mapping in LegacyRoutineMissionMapping,
          where: mapping.mission_id in ^mission_ids,
          order_by: [
            asc: mapping.mission_id,
            asc: mapping.legacy_routine_id,
            asc: mapping.mapping_id
          ]
        )
      )

    work_items =
      Repo.all(
        from(work_item in WorkItem,
          where: work_item.mission_id in ^mission_ids,
          order_by: [
            asc: work_item.mission_id,
            asc: work_item.inserted_at,
            asc: work_item.work_item_id
          ]
        )
      )

    work_item_ids = Enum.map(work_items, & &1.id)

    events =
      Repo.all(
        from(event in WorkEvent,
          where: event.mission_id in ^mission_ids,
          order_by: [
            asc: event.mission_id,
            asc: event.inserted_at,
            asc: event.event_id
          ]
        )
      )

    attempts = attempts(work_item_ids)
    gates = mission_gates(mission_ids)
    artifacts = mission_artifacts(mission_ids)

    calls =
      Repo.all(
        from(call in OperationCall,
          where: call.mission_id in ^public_mission_ids,
          order_by: [asc: call.inserted_at, asc: call.call_id]
        )
      )

    %{
      targets: group(targets, :mission_id),
      mappings: group(mappings, :mission_id),
      work_items: group(work_items, :mission_id),
      attempts: group(attempts, :work_item_id),
      gates: group(gates, :mission_id),
      artifacts: group(artifacts, :mission_id),
      events: group(events, :mission_id),
      calls: group(calls, :mission_id)
    }
  end

  defp load_work_item_context([]), do: empty_context()

  defp load_work_item_context(work_items) do
    work_item_ids = Enum.map(work_items, & &1.id)
    public_work_item_ids = Enum.map(work_items, & &1.work_item_id)
    mission_ids = work_items |> Enum.map(& &1.mission_id) |> Enum.uniq()

    targets =
      Repo.all(
        from(target in MissionTarget,
          where: target.mission_id in ^mission_ids,
          order_by: [
            asc: target.mission_id,
            asc: target.kind,
            asc: target.external_id,
            asc: target.id
          ]
        )
      )

    mappings =
      Repo.all(
        from(mapping in LegacyRoutineMissionMapping,
          where: mapping.mission_id in ^mission_ids,
          order_by: [
            asc: mapping.mission_id,
            asc: mapping.legacy_routine_id,
            asc: mapping.mapping_id
          ]
        )
      )

    events =
      Repo.all(
        from(event in WorkEvent,
          where: event.work_item_id in ^work_item_ids,
          order_by: [
            asc: event.work_item_id,
            asc: event.work_item_version,
            asc: event.inserted_at,
            asc: event.event_id
          ]
        )
      )

    calls =
      Repo.all(
        from(call in OperationCall,
          where: call.work_item_id in ^public_work_item_ids,
          order_by: [asc: call.inserted_at, asc: call.call_id]
        )
      )

    %{
      targets: group(targets, :mission_id),
      mappings: group(mappings, :mission_id),
      work_items: %{},
      attempts: attempts(work_item_ids) |> group(:work_item_id),
      gates: work_item_gates(work_item_ids) |> group(:work_item_id),
      artifacts: work_item_artifacts(work_item_ids) |> group(:work_item_id),
      events: group(events, :work_item_id),
      calls: group(calls, :work_item_id)
    }
  end

  defp attempts(work_item_ids) do
    Attempt
    |> where_ids(:work_item_id, work_item_ids)
    |> order_by_attempt()
    |> Repo.all()
    |> Repo.preload([
      :role_binding,
      :context_bundle,
      :caused_by_attempt,
      work_item: :mission
    ])
  end

  defp mission_gates(mission_ids) do
    WorkGate
    |> where_ids(:mission_id, mission_ids)
    |> order_by_gate(:mission_id)
    |> Repo.all()
    |> Repo.preload([:mission, :work_item, :attempt])
  end

  defp work_item_gates(work_item_ids) do
    WorkGate
    |> where_ids(:work_item_id, work_item_ids)
    |> order_by_gate(:work_item_id)
    |> Repo.all()
    |> Repo.preload([:mission, :work_item, :attempt])
  end

  defp mission_artifacts(mission_ids) do
    Artifact
    |> where_ids(:mission_id, mission_ids)
    |> order_by_artifact(:mission_id)
    |> Repo.all()
    |> Repo.preload([:producer_attempt, :work_item, :mission])
  end

  defp work_item_artifacts(work_item_ids) do
    Artifact
    |> where_ids(:work_item_id, work_item_ids)
    |> order_by_artifact(:work_item_id)
    |> Repo.all()
    |> Repo.preload([:producer_attempt, :work_item, :mission])
  end

  defp where_ids(queryable, field_name, ids) do
    from(row in queryable, where: field(row, ^field_name) in ^ids)
  end

  defp order_by_attempt(query) do
    from(attempt in query,
      order_by: [
        asc: attempt.work_item_id,
        asc: attempt.inserted_at,
        asc: attempt.attempt_id
      ]
    )
  end

  defp order_by_gate(query, parent_field) do
    from(gate in query,
      order_by: [
        asc: field(gate, ^parent_field),
        asc: gate.inserted_at,
        asc: gate.gate_id
      ]
    )
  end

  defp order_by_artifact(query, parent_field) do
    from(artifact in query,
      order_by: [
        asc: field(artifact, ^parent_field),
        asc: artifact.inserted_at,
        asc: artifact.artifact_id
      ]
    )
  end

  defp current_attempt(%WorkItem{active_attempt_id: nil}, attempts), do: List.last(attempts)

  defp current_attempt(%WorkItem{active_attempt_id: attempt_id}, attempts) do
    Enum.find(attempts, &(&1.attempt_id == attempt_id))
  end

  defp attempt_summary(nil, _work_item), do: nil

  defp attempt_summary(attempt, work_item) do
    %{
      attempt_id: attempt.attempt_id,
      state: attempt.state,
      active: attempt.attempt_id == work_item.active_attempt_id,
      executor_kind: attempt.executor_kind,
      provider: attempt.provider,
      profile: attempt.profile,
      recipe_version: attempt.recipe_version,
      expected_work_item_version: attempt.expected_work_item_version,
      started_at: iso8601(attempt.started_at),
      finished_at: iso8601(attempt.finished_at)
    }
  end

  defp attempt_detail(nil, _work_item), do: nil

  defp attempt_detail(attempt, work_item) do
    attempt
    |> attempt_summary(work_item)
    |> Map.merge(%{
      work_item_id: work_item.work_item_id,
      mission_id: work_item.mission.mission_id,
      role_binding_id: attempt.role_binding && attempt.role_binding.binding_id,
      context_bundle_id: attempt.context_bundle.context_bundle_id,
      caused_by_attempt_id: attempt.caused_by_attempt && attempt.caused_by_attempt.attempt_id,
      context_digest: attempt.context_digest,
      oban_job_id: attempt.oban_job_id,
      workflow_run_id: attempt.workflow_run_id,
      provider_continuation: attempt.provider_continuation,
      provenance: attempt.provenance,
      usage: attempt.usage,
      outcome: attempt.outcome,
      error_class: attempt.error_class,
      error_details: attempt.error_details,
      inserted_at: iso8601(attempt.inserted_at),
      updated_at: iso8601(attempt.updated_at)
    })
  end

  defp gate_summary(gate) do
    %{
      gate_id: gate.gate_id,
      subject_kind: gate.subject_kind,
      operation: gate.operation,
      status: gate.status,
      attempt_id: gate.attempt && gate.attempt.attempt_id,
      operation_call_id: gate.operation_call_id,
      work_item_version: gate.work_item_version,
      inserted_at: iso8601(gate.inserted_at)
    }
  end

  defp gate_detail(gate) do
    gate
    |> gate_summary()
    |> Map.merge(%{
      mission_id: gate.mission.mission_id,
      work_item_id: gate.work_item.work_item_id,
      arguments: gate.arguments,
      preview: gate.preview,
      requester: gate.requester,
      policy_version: gate.policy_version,
      grant_decision: gate.grant_decision,
      external_preconditions: gate.external_preconditions,
      definition_fingerprint: gate.definition_fingerprint,
      operation_idempotency_key: gate.operation_idempotency_key,
      correlation_id: gate.correlation_id,
      causation_id: gate.causation_id,
      updated_at: iso8601(gate.updated_at)
    })
  end

  defp artifact_summary(artifact) do
    %{
      artifact_id: artifact.artifact_id,
      kind: artifact.kind,
      producer_attempt_id: artifact.producer_attempt && artifact.producer_attempt.attempt_id,
      external_identity: artifact.external_identity,
      digest: artifact.digest,
      media_type: artifact.media_type,
      inserted_at: iso8601(artifact.inserted_at)
    }
  end

  defp artifact_detail(artifact) do
    artifact
    |> artifact_summary()
    |> Map.merge(%{
      work_item_id: artifact.work_item.work_item_id,
      mission_id: artifact.mission.mission_id,
      provenance: artifact.provenance,
      location: artifact.location,
      size_bytes: artifact.size_bytes,
      retention: artifact.retention,
      expires_at: iso8601(artifact.expires_at),
      updated_at: iso8601(artifact.updated_at)
    })
  end

  defp artifact_contract(artifact) do
    artifact
    |> artifact_detail()
    |> Map.put(:contract, "custode.artifact.v1")
  end

  defp work_event_contract(event) do
    event
    |> WorkItems.render_event()
    |> Map.merge(%{
      contract: "custode.work_event.v1",
      mission_id: event.mission.mission_id,
      work_item_id: event.work_item.work_item_id
    })
  end

  defp relevant_artifacts(artifacts) do
    now = DateTime.utc_now()

    Enum.filter(artifacts, fn
      %{expires_at: nil} -> true
      %{expires_at: expires_at} -> DateTime.compare(expires_at, now) == :gt
    end)
  end

  defp target(target) do
    %{
      kind: target.kind,
      external_id: target.external_id,
      display_name: target.display_name,
      metadata: target.metadata
    }
  end

  defp work_target(work_item, mission_targets) do
    %{
      source: work_item.source,
      external_key: work_item.external_key,
      mission_targets: Enum.map(mission_targets, &target/1)
    }
  end

  defp mission_compatibility(mappings) do
    %{
      authoritative_store: "missions",
      legacy_projection: %{
        present: mappings != [],
        read_only: true,
        projected_fields: if(mappings == [], do: [], else: @legacy_projected_fields),
        mappings: Enum.map(mappings, &legacy_mapping/1)
      }
    }
  end

  defp work_item_compatibility(mappings) do
    %{
      authoritative_store: "work_items",
      legacy_mission_scope: %{
        present: mappings != [],
        read_only: true,
        mappings: Enum.map(mappings, &legacy_mapping/1)
      }
    }
  end

  defp legacy_mapping(mapping) do
    %{
      mapping_id: mapping.mapping_id,
      legacy_routine_id: mapping.legacy_routine_id,
      strategy: mapping.strategy,
      status: mapping.status
    }
  end

  defp counts_by_state(work_items) do
    counts = Enum.frequencies_by(work_items, & &1.state)
    Map.new(@states, &{&1, Map.get(counts, &1, 0)})
  end

  defp transition_events(events), do: Enum.filter(events, &(&1.kind in @transition_kinds))
  defp event(nil), do: nil
  defp event(event), do: WorkItems.render_event(event)

  defp operation_call_ids(work_items, events, gates, calls) do
    [
      Enum.map(work_items, & &1.active_operation_call_id),
      Enum.map(events, & &1.operation_call_id),
      Enum.map(gates, & &1.operation_call_id),
      Enum.map(calls, & &1.call_id)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp group(rows, field_name), do: Enum.group_by(rows, &Map.fetch!(&1, field_name))
  defp rows(grouped, key), do: Map.get(grouped, key, [])

  defp rows_for_many(grouped, keys) do
    Enum.flat_map(keys, &rows(grouped, &1))
  end

  defp empty_context do
    %{
      targets: %{},
      mappings: %{},
      work_items: %{},
      attempts: %{},
      gates: %{},
      artifacts: %{},
      events: %{},
      calls: %{}
    }
  end

  defp options(options, defaults) when is_map(options) do
    known_keys = Keyword.keys(defaults)

    options
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, normalized} ->
      case option_key(key, known_keys) do
        {:ok, option_key} -> {:cont, {:ok, [{option_key, value} | normalized]}}
        :error -> {:halt, {:error, {:invalid_options, [key]}}}
      end
    end)
    |> case do
      {:ok, normalized} -> options(normalized, defaults)
      {:error, _reason} = error -> error
    end
  end

  defp options(options, defaults) when is_list(options) do
    case Keyword.validate(options, defaults) do
      {:ok, validated} -> {:ok, validated}
      {:error, unknown} -> {:error, {:invalid_options, unknown}}
    end
  end

  defp options(_options, _defaults), do: {:error, {:invalid_options, :expected_keyword_or_map}}

  defp option_key(key, known_keys) when is_atom(key) do
    if key in known_keys, do: {:ok, key}, else: :error
  end

  defp option_key(key, known_keys) when is_binary(key) do
    case Enum.find(known_keys, &(Atom.to_string(&1) == key)) do
      nil -> :error
      known_key -> {:ok, known_key}
    end
  end

  defp option_key(_key, _known_keys), do: :error

  defp validate_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: :ok
  defp validate_limit(limit), do: {:error, {:invalid_limit, limit}}
  defp validate_mission_scope(nil), do: :ok

  defp validate_mission_scope(mission_id) when is_binary(mission_id) and mission_id != "",
    do: :ok

  defp validate_mission_scope(mission_id),
    do: {:error, {:invalid_mission_id, mission_id}}

  defp validate_work_item_scope(nil), do: :ok

  defp validate_work_item_scope(work_item_id)
       when is_binary(work_item_id) and work_item_id != "",
       do: :ok

  defp validate_work_item_scope(work_item_id),
    do: {:error, {:invalid_work_item_id, work_item_id}}

  defp ensure_work_item_exists(nil), do: :ok

  defp ensure_work_item_exists(work_item_id) do
    case Repo.exists?(from(work_item in WorkItem, where: work_item.work_item_id == ^work_item_id)) do
      true -> :ok
      false -> {:error, {:unknown_work_item, work_item_id}}
    end
  end

  defp fetch_work_item(work_item_id) do
    case Repo.get_by(WorkItem, work_item_id: work_item_id) do
      nil -> {:error, {:unknown_work_item, work_item_id}}
      work_item -> {:ok, work_item}
    end
  end

  defp after_mission(query, nil), do: query

  defp after_mission(query, %{inserted_at: inserted_at, id: mission_id}) do
    from(mission in query,
      where:
        mission.inserted_at > ^inserted_at or
          (mission.inserted_at == ^inserted_at and mission.mission_id > ^mission_id)
    )
  end

  defp for_mission(query, nil), do: query

  defp for_mission(query, mission_id) do
    from(work_item in query,
      join: mission in Mission,
      on: mission.id == work_item.mission_id,
      where: mission.mission_id == ^mission_id
    )
  end

  defp for_work_item(query, nil), do: query

  defp for_work_item(query, work_item_id) do
    from(event in query,
      join: work_item in WorkItem,
      on: work_item.id == event.work_item_id,
      where: work_item.work_item_id == ^work_item_id
    )
  end

  defp after_work_item(query, nil), do: query

  defp after_work_item(query, %{inserted_at: inserted_at, id: work_item_id}) do
    from(work_item in query,
      where:
        work_item.inserted_at > ^inserted_at or
          (work_item.inserted_at == ^inserted_at and
             work_item.work_item_id > ^work_item_id)
    )
  end

  defp after_artifact(query, nil), do: query

  defp after_artifact(query, %{inserted_at: inserted_at, id: artifact_id}) do
    from(artifact in query,
      where:
        artifact.inserted_at > ^inserted_at or
          (artifact.inserted_at == ^inserted_at and artifact.artifact_id > ^artifact_id)
    )
  end

  defp after_work_event(query, nil), do: query

  defp after_work_event(query, %{inserted_at: inserted_at, id: event_id}) do
    from(event in query,
      where:
        event.inserted_at > ^inserted_at or
          (event.inserted_at == ^inserted_at and event.event_id > ^event_id)
    )
  end

  defp page(rows, limit, resource, scope, order) do
    has_more = length(rows) > limit
    visible = Enum.take(rows, limit)

    next_cursor =
      if has_more do
        visible
        |> List.last()
        |> encode_cursor(resource, scope)
      end

    {visible,
     %{
       limit: limit,
       has_more: has_more,
       next_cursor: next_cursor,
       order: order
     }}
  end

  defp encode_cursor(row, "mission", scope),
    do: encode_cursor_payload("mission", row.inserted_at, row.mission_id, scope)

  defp encode_cursor(row, "work_item", scope),
    do: encode_cursor_payload("work_item", row.inserted_at, row.work_item_id, scope)

  defp encode_cursor(row, "artifact", scope),
    do: encode_cursor_payload("artifact", row.inserted_at, row.artifact_id, scope)

  defp encode_cursor(row, "work_event", scope),
    do: encode_cursor_payload("work_event", row.inserted_at, row.event_id, scope)

  defp encode_cursor_payload(resource, inserted_at, id, scope) do
    %{
      "resource" => resource,
      "inserted_at" => DateTime.to_iso8601(inserted_at),
      "id" => id,
      "scope" => scope
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _resource, _scope), do: {:ok, nil}

  defp decode_cursor(cursor, resource, scope) when is_binary(cursor) do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{
            "resource" => ^resource,
            "inserted_at" => inserted_at,
            "id" => id,
            "scope" => ^scope
          }} <- Jason.decode(encoded),
         true <- is_binary(id) and id != "",
         true <- is_binary(inserted_at),
         {:ok, parsed, 0} <- DateTime.from_iso8601(inserted_at) do
      {:ok, %{inserted_at: parsed, id: id}}
    else
      _invalid -> {:error, {:invalid_cursor, cursor}}
    end
  end

  defp decode_cursor(cursor, _resource, _scope), do: {:error, {:invalid_cursor, cursor}}

  defp preload_work_item(nil), do: nil
  defp preload_work_item(work_item), do: Repo.preload(work_item, [:mission, :parent])
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
