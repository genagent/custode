defmodule Custode.GitHubIssueIntake do
  @moduledoc """
  Deterministic, bounded intake for the first `github_issue_to_merge@1` pilot.

  Pilot configuration names exact issue numbers and a stable GitHub
  repository ID. Polls and webhook deliveries converge through the WorkItem
  source key and source-revision fingerprint. GitHub marker comments remain
  recorded policy inputs, never direct lifecycle commands.
  """

  alias Custode.{LegacyMissionProjection, Mission, Missions, Repository, WorkItems}
  alias Custode.Operations.WorkItems, as: WorkOperations

  @source "github"
  @kind "github_issue_to_merge"
  @workflow_version 1

  @spec on_routine_tick(map()) :: :noop | {:ok, [map()]} | {:error, term()}
  def on_routine_tick(routine) do
    case pilot_for(routine.id) do
      nil -> :noop
      pilot -> ingest_pilot(routine, pilot)
    end
  end

  @spec reconcile(Mission.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile(%Mission{} = mission, repository_id, canonical_name, issue, options \\ []) do
    pilot = Keyword.fetch!(options, :pilot)

    with :ok <- validate_reconcile(mission, repository_id, canonical_name, issue, pilot) do
      do_reconcile(mission, repository_id, canonical_name, issue, options, pilot)
    end
  end

  defp do_reconcile(mission, repository_id, canonical_name, issue, options, pilot) do
    issue_number = value(issue, :number)
    external_key = external_key(repository_id, issue_number)
    source_snapshot = source_snapshot(repository_id, canonical_name, issue)
    revision = source_snapshot.revision
    policy_version = value(pilot, :policy_version)
    disposition = disposition(issue)

    context = %{
      correlation_id:
        Keyword.get(
          options,
          :correlation_id,
          "github-intake:#{repository_id}:issue:#{issue_number}:#{revision}"
        ),
      causation_id:
        Keyword.get(
          options,
          :causation_id,
          Keyword.get(options, :delivery_id, "github-revision:#{revision}")
        ),
      external_key: external_key,
      issue_number: issue_number,
      policy_version: policy_version,
      revision: revision,
      snapshot: source_snapshot
    }

    with {:ok, work_item, created?} <-
           ensure_work_item(mission, issue, pilot, disposition, context),
         {:ok, work_item, observed?} <- observe_changed_source(work_item, context),
         {:ok, work_item} <- apply_disposition(work_item, disposition, context) do
      {:ok,
       %{
         work_item: WorkItems.render(work_item),
         disposition: disposition,
         created: created?,
         observed: observed?
       }}
    end
  end

  defp validate_reconcile(mission, repository_id, canonical_name, issue, pilot) do
    repository_id = to_string(repository_id)
    issue_number = value(issue, :number)
    issue_numbers = value(pilot, :issue_numbers, [])

    with :ok <- validate_repository_id(repository_id, pilot),
         :ok <- validate_mission_repository(mission, repository_id),
         :ok <- validate_nonempty(canonical_name, {:invalid_source_field, :canonical_name}),
         :ok <- validate_issue_numbers(issue_numbers),
         :ok <- validate_issue_number(issue_number, issue_numbers),
         :ok <- validate_member(value(issue, :state), ["open", "closed"], :state),
         :ok <- validate_nonempty(value(issue, :updated_at), {:invalid_source_field, :updated_at}),
         :ok <- validate_list(value(issue, :labels, []), &is_binary/1, :labels),
         :ok <- validate_list(value(issue, :comments, []), &is_map/1, :comments) do
      validate_nonempty(value(pilot, :policy_version), {:invalid_pilot_field, :policy_version})
    end
  end

  defp validate_repository_id(repository_id, pilot) do
    if repository_id == to_string(value(pilot, :repository_id)),
      do: :ok,
      else: {:error, {:repository_not_approved, repository_id}}
  end

  defp validate_mission_repository(mission, repository_id) do
    case Missions.get(mission.mission_id) do
      %Mission{status: "active", targets: targets} ->
        if Enum.any?(
             targets,
             &(&1.kind == "github_repository" and &1.external_id == repository_id)
           ) do
          :ok
        else
          {:error, {:mission_repository_mismatch, mission.mission_id, repository_id}}
        end

      _inactive_or_missing ->
        {:error, {:mission_not_active, mission.mission_id}}
    end
  end

  defp validate_issue_numbers(numbers) do
    if is_list(numbers) and numbers != [] and Enum.all?(numbers, &is_integer/1),
      do: :ok,
      else: {:error, {:invalid_pilot_field, :issue_numbers}}
  end

  defp validate_issue_number(number, approved) do
    if is_integer(number) and number > 0 and number in approved,
      do: :ok,
      else: {:error, {:issue_not_approved, number}}
  end

  defp validate_member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_source_field, field}}
  end

  defp validate_nonempty(value, error) do
    if is_binary(value) and value != "", do: :ok, else: {:error, error}
  end

  defp validate_list(value, predicate, field) do
    if is_list(value) and Enum.all?(value, predicate),
      do: :ok,
      else: {:error, {:invalid_source_field, field}}
  end

  defp ingest_pilot(routine, pilot) do
    with {:ok, mapping} <- active_mapping(routine.id),
         {:ok, repository_id, canonical_name} <- approved_repository(mapping, pilot),
         {:ok, issue_numbers} <- issue_numbers(pilot) do
      reader = Application.get_env(:custode, :repository_reader, Repository)

      Enum.reduce_while(issue_numbers, {:ok, []}, fn issue_number, {:ok, results} ->
        ingest_issue(
          reader,
          routine.repo,
          issue_number,
          mapping.mission,
          repository_id,
          canonical_name,
          pilot,
          results
        )
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        error -> error
      end
    end
  end

  defp ingest_issue(
         reader,
         repository,
         issue_number,
         mission,
         repository_id,
         canonical_name,
         pilot,
         results
       ) do
    case reader.view_issue(repository, issue_number) do
      {:ok, issue} ->
        continue_reconcile(
          reconcile(mission, repository_id, canonical_name, issue, pilot: pilot),
          results
        )

      {:error, reason} ->
        {:halt, {:error, {:github_issue_read_failed, issue_number, reason}}}
    end
  end

  defp continue_reconcile({:ok, result}, results), do: {:cont, {:ok, [result | results]}}
  defp continue_reconcile({:error, reason}, _results), do: {:halt, {:error, reason}}

  defp ensure_work_item(mission, issue, pilot, disposition, context) do
    attrs = %{
      mission_id: mission.mission_id,
      kind: @kind,
      workflow_version: @workflow_version,
      objective: objective(issue),
      acceptance_criteria: acceptance_criteria(pilot, issue),
      phase: "discovered",
      priority: value(pilot, :priority) || 0,
      policy_ref: context.policy_version,
      source: @source,
      external_key: context.external_key,
      evidence: observation_evidence(context, disposition)
    }

    case WorkOperations.Create.dispatch(
           attrs,
           invocation(context, "create", context.external_key)
         ) do
      {:ok, response} ->
        with {:ok, work_item} <- response_work_item(response) do
          created? =
            not response.replayed and
              Enum.any?(response.effects, &(&1.type == "work_item_created"))

          {:ok, work_item, created?}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe_changed_source(work_item, context) do
    previous_revision =
      case WorkItems.latest_source_snapshot(work_item.work_item_id) do
        nil -> nil
        snapshot -> snapshot["revision"]
      end

    if previous_revision == context.revision do
      {:ok, work_item, false}
    else
      attrs = %{
        expected_version: work_item.version,
        evidence: observation_evidence(context, nil)
      }

      case WorkOperations.Observe.dispatch(
             work_item.work_item_id,
             attrs,
             invocation(context, "observe", context.revision)
           ) do
        {:ok, response} ->
          observed_response(response)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp observed_response(response) do
    with {:ok, work_item} <- response_work_item(response) do
      {:ok, work_item, true}
    end
  end

  defp apply_disposition(work_item, :closed, context) do
    if work_item.state in ["completed", "cancelled"] do
      {:ok, work_item}
    else
      transition(
        work_item,
        "cancelled",
        work_item.phase,
        %{
          source_snapshot: context.snapshot,
          outcome: %{
            code: "github_issue_closed",
            issue_number: context.issue_number,
            revision: context.revision
          }
        },
        context,
        "closed"
      )
    end
  end

  defp apply_disposition(work_item, :eligible, context) do
    case {work_item.state, work_item.phase} do
      {"proposed", "discovered"} ->
        with {:ok, triaging} <-
               transition(
                 work_item,
                 "proposed",
                 "triaging",
                 %{source_snapshot: context.snapshot},
                 context,
                 "triaging"
               ) do
          apply_disposition(triaging, :eligible, context)
        end

      {"proposed", "ineligible"} ->
        with {:ok, triaging} <-
               transition(
                 work_item,
                 "proposed",
                 "triaging",
                 %{source_snapshot: context.snapshot},
                 context,
                 "reevaluate"
               ) do
          apply_disposition(triaging, :eligible, context)
        end

      {"proposed", "triaging"} ->
        transition(
          work_item,
          "ready",
          "eligible",
          %{eligibility: eligibility(:eligible, context)},
          context,
          "eligible"
        )

      _other ->
        {:ok, work_item}
    end
  end

  defp apply_disposition(work_item, :ineligible, context) do
    case {work_item.state, work_item.phase} do
      {"proposed", "discovered"} ->
        with {:ok, triaging} <-
               transition(
                 work_item,
                 "proposed",
                 "triaging",
                 %{source_snapshot: context.snapshot},
                 context,
                 "triaging"
               ) do
          apply_disposition(triaging, :ineligible, context)
        end

      {"proposed", "triaging"} ->
        transition(
          work_item,
          "proposed",
          "ineligible",
          %{eligibility: eligibility(:ineligible, context)},
          context,
          "ineligible"
        )

      {"ready", "eligible"} ->
        with {:ok, blocked} <-
               transition(
                 work_item,
                 "blocked",
                 "eligible",
                 %{
                   blocked_reason: %{
                     code: "eligibility_withdrawn",
                     policy_version: context.policy_version,
                     revision: context.revision
                   }
                 },
                 context,
                 "withdraw"
               ) do
          apply_disposition(blocked, :ineligible, context)
        end

      {"blocked", "eligible"} ->
        if get_in(work_item.blocked_reason, ["code"]) == "eligibility_withdrawn" do
          transition(
            work_item,
            "proposed",
            "ineligible",
            %{eligibility: eligibility(:ineligible, context)},
            context,
            "ineligible"
          )
        else
          {:ok, work_item}
        end

      _other ->
        {:ok, work_item}
    end
  end

  defp transition(work_item, state, phase, details, context, action) do
    attrs =
      details
      |> Map.take([:blocked_reason, :outcome])
      |> Map.merge(%{
        expected_version: work_item.version,
        state: state,
        phase: phase,
        evidence:
          Map.merge(
            Map.drop(details, [:blocked_reason, :outcome]),
            %{intake: intake_evidence(context)}
          )
      })

    case WorkOperations.Transition.dispatch(
           work_item.work_item_id,
           attrs,
           invocation(context, "transition-#{action}", context.policy_version)
         ) do
      {:ok, response} -> response_work_item(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp response_work_item(%{result: %{work_item: %{work_item_id: work_item_id}}}) do
    case WorkItems.get(work_item_id) do
      nil -> {:error, {:intake_work_item_missing, work_item_id}}
      work_item -> {:ok, work_item}
    end
  end

  defp response_work_item(%{status: status}),
    do: {:error, {:intake_operation_in_progress, status}}

  defp observation_evidence(context, disposition) do
    %{
      source_snapshot: context.snapshot,
      external_updated_at: context.snapshot.external_updated_at,
      intake: Map.put(intake_evidence(context), :disposition, disposition)
    }
  end

  defp intake_evidence(context) do
    %{
      policy_version: context.policy_version,
      revision: context.revision,
      source: @source
    }
  end

  defp eligibility(disposition, context) do
    %{
      decision: Atom.to_string(disposition),
      policy_version: context.policy_version,
      reason:
        if(disposition == :eligible,
          do: "approved pilot issue",
          else: "custode:ignore label present"
        ),
      revision: context.revision
    }
  end

  defp invocation(context, action, suffix) do
    [
      actor: %{kind: :system, id: "github-issue-intake"},
      transport: :system,
      idempotency_key:
        "github-intake:" <>
          fingerprint(%{
            external_key: context.external_key,
            action: action,
            suffix: suffix,
            revision: context.revision
          }),
      correlation_id: context.correlation_id,
      causation_id: context.causation_id
    ]
  end

  defp source_snapshot(repository_id, canonical_name, issue) do
    comments = Enum.map(value(issue, :comments, []), &comment_snapshot/1)

    issue_snapshot = %{
      number: value(issue, :number),
      title: value(issue, :title),
      body: value(issue, :body),
      state: value(issue, :state),
      labels: issue |> value(:labels, []) |> Enum.sort(),
      url: value(issue, :url),
      external_updated_at: value(issue, :updated_at),
      comments: comments,
      marker: latest_marker(comments)
    }

    %{
      kind: "github_issue",
      repository_id: to_string(repository_id),
      canonical_name: canonical_name,
      issue: issue_snapshot,
      external_updated_at: issue_snapshot.external_updated_at,
      revision:
        fingerprint(%{
          repository_id: to_string(repository_id),
          canonical_name: canonical_name,
          issue: issue_snapshot
        })
    }
  end

  defp comment_snapshot(comment) do
    %{
      id: value(comment, :id),
      author: value(comment, :author),
      body: value(comment, :body),
      created_at: value(comment, :created_at),
      updated_at: value(comment, :updated_at)
    }
  end

  defp latest_marker(comments) do
    comments
    |> Enum.reduce(nil, fn comment, latest ->
      case Regex.run(~r/^\s*(ready|blocked)\s*:\s*(.+)$/is, value(comment, :body, "")) do
        [_, kind, detail] ->
          %{
            kind: String.downcase(kind),
            detail: String.trim(detail),
            comment_id: value(comment, :id),
            author: value(comment, :author),
            updated_at: value(comment, :updated_at) || value(comment, :created_at)
          }

        nil ->
          latest
      end
    end)
  end

  defp disposition(issue) do
    cond do
      value(issue, :state) == "closed" -> :closed
      Repository.ignore_label() in value(issue, :labels, []) -> :ineligible
      true -> :eligible
    end
  end

  defp acceptance_criteria(pilot, issue) do
    value(pilot, :acceptance_criteria) ||
      %{
        checks: [
          "GitHub issue ##{value(issue, :number)} acceptance is satisfied",
          "focused and full relevant checks pass",
          "pull request review is complete"
        ]
      }
  end

  defp objective(issue),
    do: "Resolve GitHub issue ##{value(issue, :number)}: #{value(issue, :title)}"

  defp external_key(repository_id, issue_number),
    do: "github:#{repository_id}:issue:#{issue_number}"

  defp active_mapping(routine_id) do
    case LegacyMissionProjection.get_by_routine(routine_id) do
      %{status: "active", mission: %Mission{status: "active"}} = mapping -> {:ok, mapping}
      nil -> {:error, {:missing_mission_mapping, routine_id}}
      mapping -> {:error, {:inactive_mission_mapping, routine_id, mapping.status}}
    end
  end

  defp approved_repository(mapping, pilot) do
    expected_id = to_string(value(pilot, :repository_id))

    case Enum.find(
           mapping.mission.targets,
           &(&1.kind == "github_repository" and &1.external_id == expected_id)
         ) do
      nil -> {:error, {:repository_not_approved, expected_id}}
      target -> {:ok, target.external_id, target.display_name}
    end
  end

  defp issue_numbers(pilot) do
    case value(pilot, :issue_numbers, []) do
      numbers when is_list(numbers) and numbers != [] ->
        if Enum.all?(numbers, &is_integer/1) do
          {:ok, Enum.sort(Enum.uniq(numbers))}
        else
          {:error, {:invalid_pilot_issue_numbers, numbers}}
        end

      invalid ->
        {:error, {:invalid_pilot_issue_numbers, invalid}}
    end
  end

  defp pilot_for(routine_id) do
    pilots = Application.get_env(:custode, :github_issue_intake_pilots, %{})
    Map.get(pilots, routine_id)
  end

  defp fingerprint(value) do
    value
    |> normalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize(nil), do: nil
  defp normalize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)
  end
end
