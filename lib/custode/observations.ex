defmodule Custode.Observations do
  @moduledoc """
  Repeated, evidence-backed drift becomes bounded control work (#246).

  A sensor that notices something wakes an agent with evidence. That is the
  right shape for one sighting and the wrong shape for a pattern: nobody is
  counting, so a condition that recurs for a month reads exactly like a
  condition that happened once. This aggregates sightings by deduplication
  key and turns a crossed threshold into one proposed control WorkItem
  instead of directly waking a named agent or mutating policy.

  ## One aggregate, not a pile of sightings

  `record/1` upserts on `dedup_key`. Seeing the same condition again
  increments `occurrences` and moves `last_observed_at`; it never inserts a
  second row. "Seen three times" is then a threshold rather than a count of
  rows nobody deduplicated.

  ## Deterministic first, model never (in this slice)

  Threshold and posture are both deterministic and versioned, so promotion
  spends no tokens and replays identically. #246 also allows routing an
  AMBIGUOUS classification through one bounded Attempt; that path is
  deliberately not built here, because every case this slice can promote is
  one a threshold already decided. Adding a model to a decision a counter
  already made would only add a way to be wrong.

  ## Policy chooses, and policy cannot widen anything

  The posture comes from #334's `Custode.WorkPolicy`: `auto` admits the
  control WorkItem, `ask` creates a Gate and leaves it waiting, `ineligible`
  records a visible refusal with a reason. Nothing here writes policy. An
  Observation is evidence, and evidence that could edit the rules it is
  judged by would not be evidence.

  ## The loop this refuses to close

  A control pathway invites one specific failure: drift raises work, the work
  produces activity, the activity looks like drift. Two independent guards:

    * an Observation whose source is control work is rejected outright and
      recorded as `rejected`, so the refusal is auditable rather than silent;
    * `Custode.WorkKinds.SystemicDriftControl.V1` never self-dispatches, so
      an admitted control item starts no Attempt that could be re-observed.

  Either alone would break the cycle. Both, because this runs unattended.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Mission, MissionTarget, Observation, Repo, WorkGates, WorkItems, WorkPolicy}
  alias Custode.Operations.WorkItems, as: WorkOperations
  alias Custode.WorkPolicy.Definition

  @threshold_version "drift:v1"
  @min_occurrences 3
  @control_kind "systemic_drift_control"
  @workflow_version 1
  @policy_version "control:v1"
  @control_source "control"

  @actor %{kind: :system, id: "observations"}

  @doc "The versioned promotion threshold."
  @spec threshold() :: map()
  def threshold do
    %{
      version: Application.get_env(:custode, :drift_threshold_version, @threshold_version),
      min_occurrences: Application.get_env(:custode, :drift_min_occurrences, @min_occurrences)
    }
  end

  @doc """
  Record one sighting, aggregating it onto its deduplication key, and promote
  the aggregate if the threshold is now met.

  Required: `:source`, `:target`, `:dedup_key`. Optional: `:revision`,
  `:evidence`, `:observed_at`.
  """
  @spec record(map() | keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def record(attrs) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :observed_at, DateTime.utc_now())

    with {:ok, attrs} <- required(attrs) do
      case upsert(attrs, now) do
        {:ok, observation} -> maybe_promote(observation)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The aggregate for one deduplication key, or nil."
  @spec get(String.t()) :: Observation.t() | nil
  def get(dedup_key) when is_binary(dedup_key),
    do: Repo.one(from(o in Observation, where: o.dedup_key == ^dedup_key))

  @doc "Aggregates still accumulating evidence, oldest first."
  @spec watching() :: [Observation.t()]
  def watching do
    Repo.all(
      from(o in Observation, where: o.disposition == "watching", order_by: [asc: o.inserted_at])
    )
  end

  @doc "Has this aggregate met the current threshold?"
  @spec due?(Observation.t()) :: boolean()
  def due?(%Observation{} = observation),
    do: observation.occurrences >= threshold().min_occurrences

  @doc """
  The versioned control-work policy: configured rules first, then the default.

  The default posture is `ask`. design/000 makes the operator the sole
  approver, and a pathway that mints its own work without asking is the one
  place that doctrine would quietly stop being true.
  """
  @spec policy_definitions() :: [Definition.t()]
  def policy_definitions do
    configured = Application.get_env(:custode, :control_work_policy, [])

    (configured ++ [default_rule()])
    |> Enum.map(&build_definition/1)
    |> Enum.reject(&is_nil/1)
  end

  defp default_rule do
    %{
      name: "control.default",
      selectors: %{work_kind: @control_kind},
      posture: :ask,
      reason: "systemic drift becomes work only when an operator says so"
    }
  end

  defp build_definition(rule) do
    rule = Map.new(rule)
    posture = normalize_posture(Map.get(rule, :posture, :ask))

    attrs = %{
      name: Map.get(rule, :name, "control.configured"),
      version: policy_version(),
      selectors: Map.put_new(Map.get(rule, :selectors, %{}), :work_kind, @control_kind),
      posture: posture,
      quality: %{verification: %{required: false}, review: %{depth: "operator"}},
      budget: %{max_spend_usd: 0.0},
      # control work runs nothing, so every execution allowance is zero
      execution: %{limits: %{max_turns: 0}, max_concurrency: 1},
      retry: %{max_infrastructure_retries: 0, max_repairs: 0},
      gates: %{required: posture == :ask, risks: ["internal_write"]},
      reason: Map.get(rule, :reason, "configured control-work posture")
    }

    case Definition.new(attrs) do
      {:ok, definition} -> definition
      {:error, _reason} -> nil
    end
  end

  defp normalize_posture(posture) when posture in [:auto, :ask, :ineligible], do: posture
  defp normalize_posture("auto"), do: :auto
  defp normalize_posture("ineligible"), do: :ineligible
  defp normalize_posture(_other), do: :ask

  defp policy_version, do: Application.get_env(:custode, :control_policy_version, @policy_version)

  defp required(attrs) do
    missing = Enum.reject([:source, :target, :dedup_key], &is_binary(attrs[&1]))

    if missing == [], do: {:ok, attrs}, else: {:error, {:missing_observation_fields, missing}}
  end

  # An observation ABOUT control work would let an admitted control item feed
  # the pathway that created it. Recorded rather than dropped, so the refusal
  # is auditable.
  defp recursive?(attrs) do
    attrs.source == @control_source or String.starts_with?(attrs.source, @control_source <> ":")
  end

  defp upsert(attrs, now) do
    case get(attrs.dedup_key) do
      nil -> insert(attrs, now)
      %Observation{} = existing -> increment(existing, attrs, now)
    end
  end

  defp insert(attrs, now) do
    %{
      observation_id: "obs-" <> Ecto.UUID.generate(),
      dedup_key: attrs.dedup_key,
      source: attrs.source,
      target: attrs.target,
      revision: attrs[:revision],
      evidence: attrs[:evidence] || %{},
      occurrences: 1,
      first_observed_at: now,
      last_observed_at: now,
      mission_id: mission_id_for(attrs.target),
      disposition: if(recursive?(attrs), do: "rejected", else: "watching"),
      disposition_reason:
        if(recursive?(attrs),
          do: %{"reason" => "an observation of control work cannot raise control work"},
          else: %{}
        )
    }
    |> Observation.create_changeset()
    |> Repo.insert()
  end

  defp increment(%Observation{disposition: "rejected"} = observation, _attrs, _now),
    do: {:ok, observation}

  defp increment(observation, attrs, now) do
    observation
    |> Ecto.Changeset.change(%{
      occurrences: observation.occurrences + 1,
      last_observed_at: now,
      revision: attrs[:revision] || observation.revision,
      evidence: Map.merge(observation.evidence || %{}, attrs[:evidence] || %{}),
      mission_id: observation.mission_id || mission_id_for(attrs.target)
    })
    |> Repo.update()
  end

  defp maybe_promote(%Observation{disposition: "watching"} = observation) do
    if due?(observation) do
      case promote(observation) do
        # no Mission yet is not a failure to record evidence; the aggregate
        # keeps watching and promotes if one appears later
        {:error, {:no_mission_for_target, _target}} -> {:ok, observation}
        result -> result
      end
    else
      {:ok, observation}
    end
  end

  defp maybe_promote(observation), do: {:ok, observation}

  @doc """
  Turn a threshold-crossing aggregate into a control WorkItem under policy.

  Idempotent by construction: every operation is keyed on the observation id,
  and an aggregate already dispositioned is returned untouched.
  """
  @spec promote(Observation.t()) :: {:ok, Observation.t()} | {:error, term()}
  def promote(%Observation{disposition: "watching"} = observation) do
    with {:ok, mission} <- mission_for(observation),
         {:ok, decision} <- decide(observation, mission) do
      apply_posture(decision.posture, observation, mission, decision)
    end
  end

  def promote(%Observation{} = observation), do: {:ok, observation}

  defp decide(observation, mission) do
    version = policy_version()

    with {:ok, registry} <- WorkPolicy.new(policy_definitions()) do
      WorkPolicy.select(registry, %{
        policy_version: version,
        work_kind: @control_kind,
        workflow_version: @workflow_version,
        target: observation.target,
        repository: observation.target,
        mission_id: mission.mission_id
      })
    end
  end

  defp apply_posture(:ineligible, observation, _mission, decision) do
    disposition(observation, %{
      disposition: "ineligible",
      disposition_reason: %{
        "reason" => decision.explanation.reason,
        "policy" => decision.name
      },
      threshold_version: threshold().version,
      policy_version: decision.version
    })
  end

  defp apply_posture(posture, observation, mission, decision) do
    with {:ok, work_item} <- create_control_work_item(observation, mission, decision) do
      case posture do
        :auto -> admit(observation, work_item, decision)
        :ask -> gate(observation, work_item, decision)
      end
    end
  end

  defp create_control_work_item(observation, mission, decision) do
    attrs = %{
      mission_id: mission.mission_id,
      kind: @control_kind,
      workflow_version: @workflow_version,
      objective: "Systemic drift on #{observation.target} crossed its threshold",
      acceptance_criteria: %{
        "decide" => "admit this as real drift, or decline it with a reason"
      },
      phase: "observed",
      policy_ref: decision.version,
      source: "observation",
      external_key: observation.observation_id,
      # the triggering evidence travels with the WorkItem, not just beside it
      evidence: %{
        "observation" => %{
          "observation_id" => observation.observation_id,
          "dedup_key" => observation.dedup_key,
          "source" => observation.source,
          "target" => observation.target,
          "revision" => observation.revision,
          "occurrences" => observation.occurrences,
          # ISO8601 rather than the struct: the operation envelope flattens
          # arguments to JSON, and a DateTime does not survive that boundary
          "first_observed_at" => iso8601(observation.first_observed_at),
          "last_observed_at" => iso8601(observation.last_observed_at),
          "evidence" => observation.evidence
        },
        "threshold" => %{
          "version" => threshold().version,
          "min_occurrences" => threshold().min_occurrences
        },
        "work_policy" => WorkPolicy.render(decision)
      }
    }

    case WorkOperations.Create.dispatch(attrs,
           actor: @actor,
           transport: :worker,
           idempotency_key: "observation:#{observation.observation_id}:control-create"
         ) do
      {:ok, %{result: %{work_item: %{work_item_id: work_item_id}}}} ->
        case WorkItems.get(work_item_id) do
          nil -> {:error, {:control_work_item_missing, work_item_id}}
          work_item -> {:ok, work_item}
        end

      {:ok, %{status: status}} ->
        {:error, {:control_work_item_not_created, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit(observation, work_item, decision) do
    case transition(work_item, %{state: "ready", phase: "admitted"}, "control-admit", decision) do
      {:ok, _response} ->
        disposition(observation, %{
          disposition: "proposed",
          disposition_reason: %{"reason" => decision.explanation.reason},
          threshold_version: threshold().version,
          policy_version: decision.version,
          control_work_item_id: work_item.work_item_id
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gate(observation, work_item, decision) do
    gate_id = "gate-" <> observation.observation_id

    with {:ok, _waiting} <-
           transition(
             work_item,
             %{
               state: "waiting",
               phase: "awaiting_decision",
               waiting_condition: %{"kind" => "gate", "gate_id" => gate_id}
             },
             "control-wait",
             decision
           ),
         waiting = WorkItems.get(work_item.work_item_id),
         {:ok, gate} <- propose_gate(waiting, gate_id, observation, decision) do
      disposition(observation, %{
        disposition: "gated",
        disposition_reason: %{"reason" => decision.explanation.reason},
        threshold_version: threshold().version,
        policy_version: decision.version,
        control_work_item_id: work_item.work_item_id,
        gate_id: gate.gate_id
      })
    end
  end

  defp transition(work_item, target, key, decision) do
    WorkOperations.Transition.dispatch(
      work_item.work_item_id,
      Map.put(target, :expected_version, work_item.version),
      actor: @actor,
      transport: :worker,
      work_policy: WorkPolicy.render(decision),
      idempotency_key: "observation:#{work_item.external_key}:#{key}"
    )
  end

  defp propose_gate(work_item, gate_id, observation, decision) do
    WorkGates.propose(
      %{
        gate_id: gate_id,
        work_item_id: work_item.work_item_id,
        subject_kind: "transition",
        operation: "work.transition",
        arguments: %{
          work_item_id: work_item.work_item_id,
          expected_version: work_item.version,
          state: "ready",
          phase: "admitted",
          evidence: %{"decision" => %{"admitted_by" => "operator"}}
        },
        policy_version: decision.version,
        external_preconditions: %{observation_occurrences: observation.occurrences},
        work_policy: WorkPolicy.render(decision),
        operation_idempotency_key: "observation:#{observation.observation_id}:control-admit"
      },
      actor: @actor,
      transport: :worker
    )
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp disposition(observation, attrs) do
    observation
    |> Observation.disposition_changeset(attrs)
    |> Repo.update()
  end

  # Without a Mission there is nothing to attach control work to. The
  # aggregate stays watching rather than failing, so a Mission that appears
  # later promotes the drift that was already accumulating.
  defp mission_for(observation) do
    case observation.mission_id && Repo.get(Mission, observation.mission_id) do
      %Mission{} = mission -> {:ok, mission}
      _absent -> {:error, {:no_mission_for_target, observation.target}}
    end
  end

  defp mission_id_for(target) do
    Repo.one(
      from(t in MissionTarget,
        where: t.display_name == ^target or t.external_id == ^target,
        select: t.mission_id,
        limit: 1
      )
    )
  end
end
