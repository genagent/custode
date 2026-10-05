defmodule Custode.OwnerReviewCancellation do
  @moduledoc "Durable queue cancellation observations; never native process settlement."
  import Ecto.Query, only: [from: 2]
  alias Custode.Repo
  @version "custode.owner_review_cancellation.v1"
  @terminal ~w(cancelled completed discarded)

  def prepare(record) do
    record
    |> Map.put("cancel_requested", true)
    |> Map.update!("children", &Enum.map(&1, fn child -> prepare_child(child, record) end))
  end

  defp prepare_child(child, record) do
    if child["status"] in ~w(queued running unconfirmed) and is_nil(child["cancellation"]) do
      Map.put(child, "cancellation", %{
        "schema_version" => @version,
        "target" => target(child, record),
        "requested_ms" => System.system_time(:millisecond),
        "state" => "pending",
        "observations" => [],
        "physical_settlement" => "unknown"
      })
    else
      child
    end
  end

  def pending?(child), do: get_in(child, ["cancellation", "state"]) == "pending"

  # The caller holds the owner admission lock and an immediate SQLite transaction.
  def deliver(child, record) do
    cancellation = child["cancellation"]

    cond do
      not pending?(child) ->
        child

      cancellation["schema_version"] != @version or
          cancellation["target"] != target(child, record) ->
        observe(child, "pending", %{
          "outcome" => "cancellation_binding_changed",
          "api_invoked" => false
        })

      true ->
        deliver_owned(child, record, Repo.get(Oban.Job, child["job_id"]))
    end
  end

  defp deliver_owned(child, _record, nil),
    do:
      observe(child, "observed", %{
        "outcome" => "job_missing",
        "api_invoked" => false,
        "job_state" => "missing"
      })

  defp deliver_owned(child, record, job) do
    cond do
      not owned?(job, child, record) ->
        observe(child, "pending", job_observation(job, "job_binding_changed", false))

      job.state in @terminal ->
        observe(child, "observed", job_observation(job, "terminal_queue_observed", false))

      true ->
        query = from(j in Oban.Job, where: j.id == ^job.id and j.worker == ^job.worker)
        {:ok, count} = Oban.cancel_all_jobs(query)
        current = Repo.get(Oban.Job, job.id)

        observation =
          current
          |> job_observation("request_api_returned", true)
          |> Map.put("queue_update_count", count)

        observe(child, "observed", observation)
    end
  end

  defp owned?(job, child, record) do
    job.worker == "Custode.OwnerReviewJob" and job.queue == "agents" and
      job.max_attempts == 1 and job.attempt in [0, 1] and
      job.args["review_id"] == record["request"]["request_id"] and
      job.args["review_attempt"] == child["attempt_id"] and
      job.args["review_slot"] == child["slot"] and
      (is_nil(child["launch_args_digest"]) or
         child["launch_args_digest"] == digest(job.args))
  end

  defp target(child, record) do
    %{
      "review_id" => record["request"]["request_id"],
      "owner_id" => record["request"]["owner_id"],
      "slot" => child["slot"],
      "attempt_id" => child["attempt_id"],
      "job_id" => child["job_id"],
      "worker" => "Custode.OwnerReviewJob",
      "queue" => "agents",
      "max_attempts" => 1,
      "allowed_job_attempts" => [0, 1],
      "launch_args_digest" => child["launch_args_digest"],
      "binding_basis" =>
        if(child["launch_args_digest"],
          do: "frozen_launch_args",
          else: "legacy_current_owned_job"
        )
    }
  end

  defp job_observation(nil, outcome, invoked),
    do: %{"outcome" => outcome, "api_invoked" => invoked, "job_state" => "missing"}

  defp job_observation(job, outcome, invoked) do
    %{
      "outcome" => outcome,
      "api_invoked" => invoked,
      "job_state" => job.state,
      "job_attempt" => job.attempt,
      "job_max_attempts" => job.max_attempts,
      "job_worker" => job.worker,
      "job_queue" => job.queue,
      "job_args_digest" => digest(job.args)
    }
  end

  defp observe(child, state, observation) do
    cancellation = child["cancellation"]
    observations = cancellation["observations"]
    fingerprint = digest(observation)

    if Enum.any?(observations, &(&1["digest"] == fingerprint)) do
      child
    else
      observation =
        observation
        |> Map.put("digest", fingerprint)
        |> Map.put("observed_ms", System.system_time(:millisecond))
        |> Map.put("physical_settlement", "unknown")

      updated =
        cancellation
        |> Map.put("state", state)
        |> Map.put("observations", Enum.take(observations ++ [observation], -8))

      Map.put(child, "cancellation", updated)
    end
  end

  def retain_job_observation(child) do
    job = Repo.get(Oban.Job, child["job_id"])
    observation = job_observation(job, "queue_state_observed", false)
    fingerprint = digest(observation)
    observations = child["job_observations"] || []

    if Enum.any?(observations, &(&1["digest"] == fingerprint)) do
      child
    else
      observed =
        observation
        |> Map.put("digest", fingerprint)
        |> Map.put("observed_ms", System.system_time(:millisecond))
        |> Map.put("basis", "durable_job_row_not_native_receipt")
        |> Map.put("physical_settlement", "unknown")

      Map.put(child, "job_observations", Enum.take(observations ++ [observed], -8))
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
