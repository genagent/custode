defmodule Custode.WorkAttribution do
  @moduledoc """
  Bounded cost, effort, and outcome summaries for the work-first kernel.

  Spend rows are the authoritative physical charge ledger. Attempt usage is
  the authoritative logical execution record. The summaries expose both and
  reconcile them, but never add them together. This prevents a provider charge
  recorded in both places from being counted twice.

  Mission, WorkItem, and RoleBinding summaries aggregate only spend rows whose
  Attempt resolves into that scope. Legacy and unknown attribution remains
  visible through `unattributed_summary/1` and is never guessed into a Mission.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Attempt,
    Attempts,
    Missions,
    OperationCall,
    Repo,
    RoleBinding,
    RoleBindings,
    WorkEvent,
    WorkItem,
    WorkItems
  }

  alias Custode.SpendLedger.Entry

  @default_limit 25
  @max_limit 100
  @attributed_statuses ~w(attempt legacy_attempt)
  @unattributed_statuses ~w(legacy_unattributed unknown_attempt)
  @disposition_states ~w(completed cancelled blocked)

  @doc "Summarize one Attempt without double counting its spend and usage."
  @spec attempt_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def attempt_summary(attempt_id, options \\ []) when is_binary(attempt_id) do
    with {:ok, limit} <- limit(options),
         attempt when not is_nil(attempt) <- Attempts.get(attempt_id) do
      charges = charges([attempt.attempt_id])
      artifacts = attempt_artifacts(attempt.id)
      calls = operation_calls([attempt.work_item.work_item_id], [attempt.attempt_id])

      {:ok,
       %{
         contract: "custode.attribution.attempt.v1",
         attempt_id: attempt.attempt_id,
         work_item_id: attempt.work_item.work_item_id,
         mission_id: attempt.work_item.mission.mission_id,
         role_binding_id: attempt.role_binding && attempt.role_binding.binding_id,
         executor_kind: attempt.executor_kind,
         provider: attempt.provider,
         profile: attempt.profile,
         recipe_version: attempt.recipe_version,
         state: attempt.state,
         expected_work_item_version: attempt.expected_work_item_version,
         usage: usage_summary([attempt], charges, limit),
         dimensions: dimensions([attempt], charges),
         outcome: attempt.outcome,
         error: error(attempt),
         evidence:
           bounded_relationships(
             %{
               artifact_ids: Enum.map(artifacts, & &1.artifact_id),
               operation_call_ids: Enum.map(calls, & &1.call_id)
             },
             limit
           ),
         aggregation_key: "attempt:#{attempt.attempt_id}",
         inserted_at: iso8601(attempt.inserted_at),
         started_at: iso8601(attempt.started_at),
         finished_at: iso8601(attempt.finished_at)
       }}
    else
      nil -> {:error, {:unknown_attempt, attempt_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Summarize cost, effort, and disposition for one WorkItem."
  @spec work_item_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def work_item_summary(work_item_id, options \\ []) when is_binary(work_item_id) do
    with {:ok, limit} <- limit(options),
         %WorkItem{} = work_item <- WorkItems.get(work_item_id) do
      attempts = attempts_for_work_items([work_item.id])
      charges = charges(Enum.map(attempts, & &1.attempt_id))
      events = events([work_item.id])
      artifacts = artifacts([work_item.id])
      calls = operation_calls([work_item.work_item_id], Enum.map(attempts, & &1.attempt_id))

      {:ok,
       %{
         contract: "custode.attribution.work_item.v1",
         work_item_id: work_item.work_item_id,
         mission_id: work_item.mission.mission_id,
         kind: work_item.kind,
         workflow_version: work_item.workflow_version,
         state: work_item.state,
         phase: work_item.phase,
         version: work_item.version,
         usage: usage_summary(attempts, charges, limit),
         repair_effort: repair_effort(attempts, charges),
         outcomes: outcome_summary([work_item], attempts, events, artifacts, limit),
         dimensions: dimensions(attempts, charges),
         relationships:
           bounded_relationships(
             %{
               attempt_ids: Enum.map(attempts, & &1.attempt_id),
               operation_call_ids: Enum.map(calls, & &1.call_id)
             },
             limit
           ),
         aggregation_key: "work_item:#{work_item.work_item_id}"
       }}
    else
      nil -> {:error, {:unknown_work_item, work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Summarize cost, effort, and outcomes for one Mission."
  @spec mission_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mission_summary(mission_id, options \\ []) when is_binary(mission_id) do
    with {:ok, limit} <- limit(options),
         mission when not is_nil(mission) <- Missions.get(mission_id) do
      work_items = mission_work_items(mission.id)
      work_item_ids = Enum.map(work_items, & &1.id)
      attempts = attempts_for_work_items(work_item_ids)
      charges = charges(Enum.map(attempts, & &1.attempt_id))
      events = events(work_item_ids)
      artifacts = artifacts(work_item_ids)

      calls =
        operation_calls(
          Enum.map(work_items, & &1.work_item_id),
          Enum.map(attempts, & &1.attempt_id)
        )

      {:ok,
       %{
         contract: "custode.attribution.mission.v1",
         mission_id: mission.mission_id,
         key: mission.key,
         lifecycle: mission.lifecycle,
         status: mission.status,
         usage: usage_summary(attempts, charges, limit),
         repair_effort: repair_effort(attempts, charges),
         outcomes: outcome_summary(work_items, attempts, events, artifacts, limit),
         dimensions: dimensions(attempts, charges),
         relationships:
           bounded_relationships(
             %{
               work_item_ids: Enum.map(work_items, & &1.work_item_id),
               attempt_ids: Enum.map(attempts, & &1.attempt_id),
               operation_call_ids: Enum.map(calls, & &1.call_id)
             },
             limit
           ),
         aggregation_key: "mission:#{mission.mission_id}"
       }}
    else
      nil -> {:error, {:unknown_mission, mission_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Summarize the work performed under one RoleBinding."
  @spec role_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def role_summary(binding_id, options \\ []) when is_binary(binding_id) do
    with {:ok, limit} <- limit(options),
         %RoleBinding{} = binding <- RoleBindings.get(binding_id) do
      attempts = role_attempts(binding.id)
      work_items = attempts |> Enum.map(& &1.work_item) |> Enum.uniq_by(& &1.id)
      work_item_ids = Enum.map(work_items, & &1.id)
      charges = charges(Enum.map(attempts, & &1.attempt_id))
      events = events(work_item_ids)
      artifacts = artifacts(work_item_ids)
      calls = operation_calls([], Enum.map(attempts, & &1.attempt_id))

      {:ok,
       %{
         contract: "custode.attribution.role.v1",
         role_binding_id: binding.binding_id,
         mission_id: binding.mission.mission_id,
         key: binding.key,
         template_key: binding.template_key,
         template_version: binding.template_version,
         authority_source: binding.authority_source,
         legacy_routine_id: binding.legacy_routine_id,
         usage: usage_summary(attempts, charges, limit),
         repair_effort: repair_effort(attempts, charges),
         outcomes: outcome_summary(work_items, attempts, events, artifacts, limit),
         dimensions: dimensions(attempts, charges),
         relationships:
           bounded_relationships(
             %{
               work_item_ids: Enum.map(work_items, & &1.work_item_id),
               attempt_ids: Enum.map(attempts, & &1.attempt_id),
               operation_call_ids: Enum.map(calls, & &1.call_id)
             },
             limit
           ),
         aggregation_key: "role_binding:#{binding.binding_id}"
       }}
    else
      nil -> {:error, {:unknown_role_binding, binding_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Summarize explicitly unattributed legacy or unknown spend.

  The totals cover all matching history. `recent` is newest first and bounded
  by `:limit` so policy readers cannot accidentally load the whole ledger.
  """
  @spec unattributed_summary(keyword()) :: {:ok, map()} | {:error, term()}
  def unattributed_summary(options \\ []) do
    with {:ok, limit} <- limit(options) do
      entries =
        Repo.all(
          from(entry in Entry,
            where: entry.attribution_status in ^@unattributed_statuses,
            order_by: [desc: entry.inserted_at, desc: entry.id]
          )
        )

      {:ok,
       %{
         contract: "custode.attribution.unattributed.v1",
         usage: charge_totals(entries),
         by_status:
           entries
           |> Enum.group_by(& &1.attribution_status)
           |> Map.new(fn {status, rows} -> {status, charge_totals(rows)} end),
         recent: entries |> Enum.take(limit) |> Enum.map(&unattributed_entry/1),
         recent_limit: limit,
         recent_truncated: length(entries) > limit,
         aggregation_key: "unattributed"
       }}
    end
  end

  defp usage_summary(attempts, charges, limit) do
    ledger = charge_totals(charges)
    reported = reported_totals(attempts)
    reconciliation = reconcile(attempts, charges, limit)

    %{
      attributed_cost_usd: ledger.cost_usd,
      physical_charges: ledger,
      logical_attempt_usage: reported,
      reconciliation: reconciliation
    }
  end

  defp charge_totals(entries) do
    Enum.reduce(
      entries,
      %{
        cost_usd: 0.0,
        charges: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_tokens: 0,
        cache_read_tokens: 0
      },
      fn entry, totals ->
        %{
          cost_usd: totals.cost_usd + (entry.cost_usd || 0.0),
          charges: totals.charges + 1,
          input_tokens: totals.input_tokens + (entry.input_tokens || 0),
          output_tokens: totals.output_tokens + (entry.output_tokens || 0),
          cache_creation_tokens:
            totals.cache_creation_tokens + (entry.cache_creation_tokens || 0),
          cache_read_tokens: totals.cache_read_tokens + (entry.cache_read_tokens || 0)
        }
      end
    )
  end

  defp reported_totals(attempts) do
    Enum.reduce(
      attempts,
      %{
        reported_cost_usd: 0.0,
        attempts: length(attempts),
        duration_ms: 0,
        commands: 0,
        model_turns: 0
      },
      fn attempt, totals ->
        usage = attempt.usage || %{}

        %{
          reported_cost_usd: totals.reported_cost_usd + number(usage, "cost_usd"),
          attempts: totals.attempts,
          duration_ms: totals.duration_ms + integer(usage, "duration_ms"),
          commands: totals.commands + integer(usage, "commands"),
          model_turns: totals.model_turns + integer(usage, "num_turns")
        }
      end
    )
  end

  defp reconcile(attempts, charges, limit) do
    charges_by_attempt = Enum.group_by(charges, & &1.attempt_id)

    differences =
      Enum.flat_map(attempts, fn attempt ->
        reported = number(attempt.usage || %{}, "cost_usd")

        recorded =
          charges_by_attempt
          |> Map.get(attempt.attempt_id, [])
          |> Enum.reduce(0.0, &((&1.cost_usd || 0.0) + &2))

        if close?(reported, recorded) do
          []
        else
          [
            %{
              attempt_id: attempt.attempt_id,
              reported_cost_usd: reported,
              recorded_cost_usd: recorded,
              delta_usd: recorded - reported
            }
          ]
        end
      end)

    %{
      status: if(differences == [], do: "reconciled", else: "difference"),
      differences: Enum.take(differences, limit),
      difference_count: length(differences),
      differences_truncated: length(differences) > limit
    }
  end

  defp repair_effort(attempts, charges) do
    repairs = Enum.filter(attempts, &repair_attempt?/1)
    repair_ids = MapSet.new(repairs, & &1.attempt_id)
    repair_charges = Enum.filter(charges, &MapSet.member?(repair_ids, &1.attempt_id))
    reported = reported_totals(repairs)

    %{
      attempts: length(repairs),
      attributed_cost_usd: charge_totals(repair_charges).cost_usd,
      duration_ms: reported.duration_ms,
      commands: reported.commands,
      model_turns: reported.model_turns
    }
  end

  defp repair_attempt?(attempt) do
    outcome_kind = get_in(attempt.outcome || %{}, ["kind"])

    not is_nil(get_in(attempt.provenance || %{}, ["repair_disposition"])) or
      get_in(attempt.provenance || %{}, ["active_phase"]) == "repairing" or
      outcome_kind in ["deterministic_repair", "semantic_repair"]
  end

  defp outcome_summary(work_items, attempts, events, artifacts, limit) do
    events_by_work = Enum.group_by(events, & &1.work_item_id)
    artifacts_by_work = Enum.group_by(artifacts, & &1.work_item_id)

    disposition_items =
      work_items
      |> Enum.filter(&(&1.state in @disposition_states))
      |> Enum.sort_by(&{timestamp(&1.updated_at), &1.work_item_id}, :desc)

    %{
      work_item_states: frequencies(work_items, & &1.state),
      attempt_states: frequencies(attempts, & &1.state),
      dispositions:
        disposition_items
        |> Enum.take(limit)
        |> Enum.map(
          &disposition(
            &1,
            Map.get(events_by_work, &1.id, []),
            Map.get(artifacts_by_work, &1.id, []),
            limit
          )
        ),
      disposition_limit: limit,
      dispositions_truncated: length(disposition_items) > limit
    }
  end

  defp disposition(work_item, events, artifacts, limit) do
    latest_event =
      events
      |> Enum.sort_by(&{&1.work_item_version, timestamp(&1.inserted_at), &1.event_id})
      |> List.last()

    %{
      work_item_id: work_item.work_item_id,
      state: work_item.state,
      phase: work_item.phase,
      outcome: work_item.outcome,
      blocked_reason: work_item.blocked_reason,
      evidence: %{
        last_event_id: latest_event && latest_event.event_id,
        last_event_evidence: latest_event && latest_event.evidence,
        artifact_ids: bounded_ids(artifacts, & &1.artifact_id, limit),
        artifact_count: length(artifacts),
        artifacts_truncated: length(artifacts) > limit
      }
    }
  end

  defp bounded_relationships(relationships, limit) do
    counts = Map.new(relationships, fn {key, ids} -> {key, length(ids)} end)
    truncated = Map.new(relationships, fn {key, ids} -> {key, length(ids) > limit} end)

    relationships
    |> Map.new(fn {key, ids} -> {key, Enum.take(ids, limit)} end)
    |> Map.merge(%{counts: counts, truncated: truncated, limit: limit})
  end

  defp bounded_ids(rows, mapper, limit) do
    rows
    |> Enum.sort_by(&{timestamp(&1.inserted_at), mapper.(&1)})
    |> Enum.take(limit)
    |> Enum.map(mapper)
  end

  defp dimensions(attempts, charges) do
    %{
      providers: frequencies(attempts, & &1.provider),
      models: frequencies(charges, & &1.model),
      executor_kinds: frequencies(attempts, & &1.executor_kind),
      workflow_phases: frequencies(charges, & &1.workflow_phase),
      role_binding_ids:
        frequencies(attempts, fn attempt ->
          attempt.role_binding && attempt.role_binding.binding_id
        end)
    }
  end

  defp frequencies(rows, mapper) do
    rows
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp error(%{error_class: nil, error_details: nil}), do: nil

  defp error(attempt) do
    %{class: attempt.error_class, details: attempt.error_details}
  end

  defp unattributed_entry(entry) do
    %{
      spend_id: entry.id,
      attribution_status: entry.attribution_status,
      attribution_key: entry.attribution_key,
      agent_id: entry.agent_id,
      legacy_routine_id: entry.legacy_routine_id,
      unresolved_attempt_id: entry.attempt_id,
      provider: entry.provider,
      model: entry.model,
      outcome: entry.outcome,
      cost_usd: entry.cost_usd,
      inserted_at: iso8601(entry.inserted_at)
    }
  end

  defp mission_work_items(mission_id) do
    Repo.all(
      from(work_item in WorkItem,
        where: work_item.mission_id == ^mission_id,
        order_by: [asc: work_item.inserted_at, asc: work_item.work_item_id]
      )
    )
    |> Repo.preload(:mission)
  end

  defp attempts_for_work_items([]), do: []

  defp attempts_for_work_items(work_item_ids) do
    Repo.all(
      from(attempt in Attempt,
        where: attempt.work_item_id in ^work_item_ids,
        order_by: [asc: attempt.inserted_at, asc: attempt.attempt_id]
      )
    )
    |> Repo.preload([:role_binding, work_item: :mission])
  end

  defp role_attempts(role_binding_id) do
    Repo.all(
      from(attempt in Attempt,
        where: attempt.role_binding_id == ^role_binding_id,
        order_by: [asc: attempt.inserted_at, asc: attempt.attempt_id]
      )
    )
    |> Repo.preload([:role_binding, work_item: :mission])
  end

  defp charges([]), do: []

  defp charges(attempt_ids) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.attempt_id in ^attempt_ids and
            entry.attribution_status in ^@attributed_statuses,
        order_by: [asc: entry.inserted_at, asc: entry.id]
      )
    )
  end

  defp events([]), do: []

  defp events(work_item_ids) do
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
  end

  defp artifacts([]), do: []

  defp artifacts(work_item_ids) do
    Repo.all(
      from(artifact in Artifact,
        where: artifact.work_item_id in ^work_item_ids,
        order_by: [
          asc: artifact.work_item_id,
          asc: artifact.inserted_at,
          asc: artifact.artifact_id
        ]
      )
    )
  end

  defp attempt_artifacts(attempt_id) do
    Repo.all(
      from(artifact in Artifact,
        where: artifact.producer_attempt_id == ^attempt_id,
        order_by: [asc: artifact.inserted_at, asc: artifact.artifact_id]
      )
    )
  end

  defp operation_calls([], []), do: []

  defp operation_calls(work_item_ids, attempt_ids) do
    Repo.all(
      from(call in OperationCall,
        where: call.work_item_id in ^work_item_ids or call.attempt_id in ^attempt_ids,
        order_by: [asc: call.inserted_at, asc: call.call_id]
      )
    )
  end

  defp limit(options) when is_list(options) do
    case Keyword.validate(options, limit: @default_limit) do
      {:ok, options} ->
        case options[:limit] do
          limit when is_integer(limit) and limit in 1..@max_limit -> {:ok, limit}
          invalid -> {:error, {:invalid_limit, invalid}}
        end

      {:error, unknown} ->
        {:error, {:invalid_options, unknown}}
    end
  end

  defp limit(_options), do: {:error, {:invalid_options, :expected_keyword}}

  defp number(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_number(value) -> value * 1.0
      _missing -> 0.0
    end
  end

  defp integer(map, key), do: trunc(number(map, key))
  defp close?(left, right), do: abs(left - right) < 1.0e-9
  defp timestamp(nil), do: 0
  defp timestamp(datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
