defmodule Custode.GitHubReview.Reconciler do
  @moduledoc """
  Durable reconciliation of pull-request review, conflict, and check evidence.

  Identifier-rich observations are persisted before their deterministic
  decision. A stable WorkItem Operation key makes a crash between evidence,
  transition, and physical scheduling replay-safe.
  """

  alias Custode.{
    Artifact,
    Artifacts,
    GitHubIssueVertical,
    Repository,
    WorkItems
  }

  alias Custode.GitHubReview.Observation
  alias Custode.Operations.WorkItems, as: WorkOperations

  @doc "Read one scoped GitHub snapshot and reconcile it without a provider."
  def reconcile(work_item_id, options) when is_binary(work_item_id) and is_list(options) do
    with work_item when not is_nil(work_item) <- WorkItems.get(work_item_id),
         {:ok, repository, number} <- waiting_scope(work_item),
         {:ok, snapshot} <- Repository.review_snapshot(repository, number),
         {:ok, observation} <- Observation.from_snapshot(repository, number, snapshot) do
      ingest(work_item_id, observation, options)
    else
      nil -> {:error, {:unknown_work_item, work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Ingest a webhook or caller-supplied observation through the same path."
  def ingest(work_item_id, observation_or_attrs, options)
      when is_binary(work_item_id) and is_list(options) do
    with {:ok, observation} <- observation(observation_or_attrs),
         work_item when not is_nil(work_item) <- WorkItems.get(work_item_id) do
      case Artifacts.get_by_external_identity(observation.external_identity) do
        %Artifact{} = artifact ->
          replay_existing(work_item, observation, artifact, options)

        nil ->
          ingest_new(work_item, observation, options)
      end
    else
      nil -> {:error, {:unknown_work_item, work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  defp ingest_new(work_item, observation, options) do
    observation = Observation.without_consumed(observation, consumed_tokens(work_item))

    if Observation.empty?(observation) do
      {:ok, %{status: :duplicate, work_item: WorkItems.render(work_item), action: :none}}
    else
      ingest_nonempty(work_item, observation, options)
    end
  end

  defp ingest_nonempty(work_item, observation, options) do
    case current_scope(work_item, observation) do
      :ok ->
        persist_and_apply(work_item, observation, options)

      {:stale, reason, observed} ->
        persist_rejection(work_item, observation, reason, observed, options)
    end
  end

  defp persist_and_apply(work_item, observation, options) do
    with {:ok, artifact} <- persist(work_item, observation, true, options) do
      apply_observation(work_item, observation, artifact, options)
    end
  end

  defp persist_rejection(work_item, observation, reason, observed, options) do
    with {:ok, artifact} <- persist(work_item, observation, false, options) do
      {:error,
       {:stale, reason, Map.put(observed, :observation_artifact_id, artifact.artifact_id)}}
    end
  end

  defp replay_existing(work_item, _observation, artifact, options) do
    accepted? = artifact.provenance["accepted"] || artifact.provenance[:accepted]

    if accepted? do
      with {:ok, observation} <- observation_from_artifact(artifact),
           :ok <- replay_scope(work_item, observation, artifact) do
        apply_observation(work_item, observation, artifact, options)
      end
    else
      {:error,
       {:stale, :github_observation_previously_rejected,
        %{observation_artifact_id: artifact.artifact_id}}}
    end
  end

  defp replay_scope(work_item, observation, artifact) do
    if applied?(work_item, artifact.external_identity) do
      :ok
    else
      case current_scope(work_item, observation) do
        :ok ->
          :ok

        {:stale, reason, observed} ->
          {:error,
           {:stale, reason, Map.put(observed, :observation_artifact_id, artifact.artifact_id)}}
      end
    end
  end

  defp applied?(work_item, external_identity) do
    work_item.work_item_id
    |> WorkItems.list_events()
    |> Enum.any?(fn event ->
      get_in(event.evidence || %{}, ["github_observation", "external_identity"]) ==
        external_identity
    end)
  end

  defp observation_from_artifact(artifact) do
    with {:ok, body} <- File.read(artifact.location),
         true <- Artifacts.digest(body) == artifact.digest,
         {:ok, attrs} <- Jason.decode(body),
         {:ok, observation} <- Observation.new(attrs) do
      {:ok, %{observation | external_identity: artifact.external_identity}}
    else
      false -> {:error, :github_observation_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp apply_observation(work_item, observation, artifact, options) do
    action = Observation.action(observation)
    idempotency_key = operation_key(artifact.external_identity, action)

    result =
      case action.kind do
        :wait ->
          WorkOperations.Observe.dispatch(
            work_item.work_item_id,
            %{
              expected_version: work_item.version,
              evidence: %{
                source_snapshot: Observation.render(observation),
                external_updated_at: observation.external_updated_at,
                github_observation: event_evidence(observation, artifact, action)
              }
            },
            operation_options(idempotency_key, artifact, options)
          )

        :repair ->
          WorkOperations.Transition.dispatch(
            work_item.work_item_id,
            %{
              expected_version: work_item.version,
              state: "ready",
              phase: action.phase,
              evidence: %{
                github_observation: event_evidence(observation, artifact, action),
                review_repair: action
              }
            },
            operation_options(idempotency_key, artifact, options)
          )
      end

    finish(result, work_item.work_item_id, observation, artifact, action, options)
  end

  defp finish({:ok, response}, work_item_id, observation, artifact, action, options) do
    with :ok <- schedule(action, work_item_id, options) do
      {:ok,
       %{
         status: if(action.kind == :repair, do: :repair_ready, else: :waiting),
         action: action,
         observation: observation,
         artifact: artifact,
         operation_call_id: response.call_id,
         replayed: response.replayed,
         work_item: WorkItems.get(work_item_id)
       }}
    end
  end

  defp finish({:error, reason}, _work_item_id, _observation, _artifact, _action, _options),
    do: {:error, reason}

  defp schedule(%{kind: :wait}, _work_item_id, _options), do: :ok

  defp schedule(%{kind: :repair}, work_item_id, options) do
    case Keyword.fetch(options, :routine_id) do
      {:ok, routine_id} -> enqueue_repair(routine_id, work_item_id, options)
      :error -> {:error, :review_repair_routine_required}
    end
  end

  defp enqueue_repair(routine_id, work_item_id, options) do
    schedule_options =
      [enqueue_fun: options[:enqueue_fun]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case GitHubIssueVertical.schedule_work_item(routine_id, work_item_id, schedule_options) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:review_repair_enqueue_failed, reason}}
    end
  end

  defp persist(work_item, observation, accepted?, options) do
    body = Jason.encode!(Observation.render(observation))
    artifact_id = artifact_id(observation.external_identity)

    attrs = %{
      artifact_id: artifact_id,
      kind: "github_observation",
      external_identity: observation.external_identity,
      media_type: "application/json",
      provenance: %{
        source: "github",
        accepted: accepted?,
        repository: observation.repository,
        pull_request_number: observation.pull_request_number,
        head_sha: observation.head_sha,
        external_updated_at: observation.external_updated_at,
        item_tokens: observation.item_tokens
      },
      retention: %{until: "work_item_terminal"}
    }

    case Artifacts.put(
           work_item.work_item_id,
           body,
           attrs,
           artifact_options(options)
         ) do
      {:ok, artifact} ->
        {:ok, artifact}

      {:error, {:artifact_write, :eexist}} ->
        existing_artifact(observation, body)

      {:error, %Ecto.Changeset{}} ->
        existing_artifact(observation, body)

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_artifact(observation, body) do
    case Artifacts.get_by_external_identity(observation.external_identity) do
      %Artifact{} = artifact ->
        if artifact.digest == Artifacts.digest(body),
          do: {:ok, artifact},
          else: {:error, :github_observation_identity_conflict}

      nil ->
        {:error, :github_observation_evidence_unavailable}
    end
  end

  defp current_scope(work_item, observation) do
    condition = work_item.waiting_condition || %{}
    latest_updated_at = latest_external_updated_at(work_item)

    result =
      with :ok <- review_waiting(work_item),
           :ok <-
             equal(
               value(condition, :name),
               "github_pull_request",
               :github_review_waiting_condition_changed
             ),
           :ok <-
             equal(
               value(condition, :repository),
               observation.repository,
               :github_review_repository_changed
             ),
           :ok <-
             equal(
               value(condition, :number),
               observation.pull_request_number,
               :github_review_pull_request_changed
             ),
           :ok <-
             equal(
               value(condition, :head_sha),
               observation.head_sha,
               :github_review_head_changed
             ) do
        not_older(observation.external_updated_at, latest_updated_at)
      end

    case result do
      :ok -> :ok
      {:stale, reason} -> stale(reason, work_item, observation)
    end
  end

  defp review_waiting(%{state: "waiting", phase: "awaiting_review"}), do: :ok
  defp review_waiting(_work_item), do: {:stale, :github_review_not_waiting}

  defp equal(value, value, _reason), do: :ok
  defp equal(_observed, _expected, reason), do: {:stale, reason}

  defp not_older(observed, recorded) do
    if older?(observed, recorded),
      do: {:stale, :github_review_revision_older},
      else: :ok
  end

  defp waiting_scope(work_item) do
    condition = work_item.waiting_condition || %{}
    repository = value(condition, :repository)
    number = value(condition, :number)

    if work_item.state == "waiting" and work_item.phase == "awaiting_review" and
         is_binary(repository) and is_integer(number) do
      {:ok, repository, number}
    else
      {:error, :github_review_waiting_scope_missing}
    end
  end

  defp latest_external_updated_at(work_item) do
    work_item.work_item_id
    |> WorkItems.list_events()
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      get_in(event.evidence || %{}, ["github_observation", "external_updated_at"])
    end)
  end

  defp consumed_tokens(work_item) do
    work_item.work_item_id
    |> WorkItems.list_events()
    |> Enum.flat_map(fn event ->
      get_in(event.evidence || %{}, ["github_observation", "item_tokens"]) || []
    end)
    |> MapSet.new()
  end

  defp event_evidence(observation, artifact, action) do
    %{
      artifact_id: artifact.artifact_id,
      external_identity: observation.external_identity,
      repository: observation.repository,
      pull_request_number: observation.pull_request_number,
      head_sha: observation.head_sha,
      base_sha: observation.conflict[:base_sha],
      external_updated_at: observation.external_updated_at,
      item_tokens: observation.item_tokens,
      action: action
    }
  end

  defp operation_options(idempotency_key, artifact, options) do
    [
      actor: %{kind: :system, id: "github-review-reconciler"},
      transport: :worker,
      idempotency_key: idempotency_key,
      correlation_id: options[:correlation_id] || "github-review:#{artifact.artifact_id}",
      causation_id: options[:causation_id] || artifact.external_identity
    ]
  end

  defp operation_key(external_identity, action) do
    suffix = if action.kind == :repair, do: "repair", else: "wait"
    "#{external_identity}:#{suffix}"
  end

  defp artifact_id(external_identity) do
    digest =
      external_identity
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "github-observation:#{digest}"
  end

  defp stale(reason, work_item, observation) do
    {:stale, reason,
     %{
       work_item: %{
         state: work_item.state,
         phase: work_item.phase,
         version: work_item.version,
         waiting_condition: work_item.waiting_condition
       },
       observation: %{
         repository: observation.repository,
         pull_request_number: observation.pull_request_number,
         head_sha: observation.head_sha,
         external_updated_at: observation.external_updated_at
       }
     }}
  end

  defp older?(_observed, nil), do: false

  defp older?(observed, recorded) do
    with {:ok, observed_at, _offset} <- DateTime.from_iso8601(observed),
         {:ok, recorded_at, _offset} <- DateTime.from_iso8601(recorded) do
      DateTime.before?(observed_at, recorded_at)
    else
      _invalid -> true
    end
  end

  defp observation(%Observation{} = observation), do: {:ok, observation}
  defp observation(attrs), do: Observation.new(attrs)

  defp artifact_options(options) do
    [artifact_dir: options[:artifact_dir]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
