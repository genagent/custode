defmodule Custode.Assurance.Sources do
  @moduledoc "Recorder-owned adapters. Authored propositions retain their original class."
  alias Custode.{ExecutionFacts, OwnerReviews, Repo, Repository, SubjectDocuments}

  def producer(owner_id, job_id) do
    turn = ExecutionFacts.read(owner_id).turns |> Enum.find(&(&1.id == job_id))
    execution(turn, owner_id)
  end

  def capture(actor, record, source) do
    case source do
      %{"kind" => "owner_review", "review_id" => id, "slot" => slot} ->
        review(actor, record, id, slot)

      %{"kind" => "document", "request_id" => id} ->
        document(actor, record, id)

      %{"kind" => "execution", "job_id" => id} ->
        observed_execution(record, id)

      %{"kind" => "repository_check", "name" => name} ->
        repository(record, name)

      _unknown ->
        {:error, :unsupported_source}
    end
  end

  def review_input(attempt) do
    attempt
    |> Map.take(~w(objective input artifact criteria case_revision policy_digest generation))
    |> Jason.encode!()
  end

  defp review(actor, record, id, slot) do
    with %OwnerReviews.Row{owner_id: owner} = row <- Repo.get(OwnerReviews.Row, id),
         true <- owner == record["owner_id"],
         {:ok, _projection} <- OwnerReviews.read(actor, id),
         %{} = child <- Enum.find(row.record["children"], &(&1["slot"] == slot)) do
      attempt = record["current"]
      bound = row.record["request"]["evidence"] == review_input(attempt)
      completed = child["status"] == "completed" and is_map(child["result"])
      verdict = if completed, do: child["result"]["verdict"]

      outcome =
        case verdict do
          "clean" -> "passed"
          "findings" -> "failed"
          _unknown -> "unknown"
        end

      {:ok,
       %{
         "kind" => "owner_review",
         "claim_class" => "self_reported",
         "outcome" => outcome,
         "execution" => nil,
         "missing_bindings" =>
           if(bound, do: [], else: ["review_input_revision"]) ++
             if(completed, do: [], else: ["completed_review"]),
         "limits" => ["native_provider_run_identity_unavailable", "opinion_is_not_reproduction"],
         "source" => %{
           "review_id" => id,
           "slot" => slot,
           "job_id" => child["job_id"],
           "attempt_id" => child["attempt_id"],
           "record_digest" => Custode.Assurance.digest(row.record)
         },
         "snapshot" => child
       }}
    else
      _missing -> {:error, :review_source_unavailable}
    end
  end

  defp document(actor, record, id) do
    artifact = record["current"]["artifact"]

    with %{"kind" => "document", "root_id" => root, "path" => path} <- artifact,
         {:ok, receipt} <-
           SubjectDocuments.invoke(actor, %{
             "action" => "receipt",
             "root_id" => root,
             "request_id" => id
           }),
         {:ok, current} <-
           SubjectDocuments.invoke(actor, %{"action" => "read", "root_id" => root, "path" => path}) do
      published =
        receipt["status"] == "created" and
          (receipt["request"]["destination"] || receipt["request"]["path"]) == path and
          get_in(receipt, ["result", "revision"]) == artifact["revision"]

      current_matches = current["revision"] == artifact["revision"]

      {:ok,
       %{
         "kind" => "document",
         "claim_class" => "host_observed",
         "outcome" => document_outcome(published, current_matches),
         "execution" => nil,
         "missing_bindings" => if(published, do: [], else: ["published_artifact_revision"]),
         "limits" => ["presence_is_not_research_acceptance"],
         "source" => %{"request_id" => id, "root_id" => root, "path" => path},
         "snapshot" => %{"receipt" => receipt, "current_revision" => current["revision"]}
       }}
    else
      _missing -> {:error, :document_source_unavailable}
    end
  end

  defp document_outcome(false, _current), do: "unknown"
  defp document_outcome(true, true), do: "passed"
  defp document_outcome(true, false), do: "failed"

  defp observed_execution(record, id) do
    execution = producer(record["owner_id"], id)
    exact = not is_nil(execution) and execution == record["current"]["producer"]

    {:ok,
     %{
       "kind" => "execution",
       "claim_class" => "host_observed",
       "outcome" => if(exact, do: "passed", else: "unknown"),
       "execution" => execution,
       "missing_bindings" => if(exact, do: [], else: ["frozen_producer_execution"]),
       "limits" => ["captured_job_is_not_artifact_verification"],
       "source" => %{"job_id" => id},
       "snapshot" => execution
     }}
  end

  defp repository(record, name) do
    case record["current"]["artifact"] do
      %{"kind" => "repository", "repository" => repository, "revision" => revision} ->
        with {:ok, checks} <- Repository.checks_for_ref(repository, revision) do
          check = Enum.find(checks, &(value(&1, :name) == name))

          {:ok,
           %{
             "kind" => "repository_check",
             "claim_class" => "unverified_attestation",
             "outcome" => "unknown",
             "execution" => nil,
             "missing_bindings" => ["configured_issuer", "check_head_revision"],
             "limits" => ["existing_repository_projection_omits_issuer_and_check_head"],
             "source" => %{
               "repository" => repository,
               "requested_head" => revision,
               "name" => name
             },
             "snapshot" => json(check)
           }}
        end

      _other ->
        {:error, :repository_artifact_required}
    end
  end

  defp execution(nil, _owner), do: nil

  defp execution(turn, owner) do
    if Enum.all?([turn.provider, turn.generation, turn.turn_id, turn.config_revision], &text?/1) do
      %{
        "actor" => owner,
        "provider" => turn.provider,
        "run_id" => "#{turn.id}:#{turn.attempt}:#{turn.generation}:#{turn.turn_id}",
        "revision" => turn.config_revision,
        "job_id" => turn.id,
        "generation" => turn.generation,
        "turn_id" => turn.turn_id
      }
    end
  end

  defp text?(value), do: is_binary(value) and value != ""
  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
