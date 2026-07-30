defmodule Custode.RepositoryHealth do
  @moduledoc """
  Repository health projected from deterministic verification evidence (#245).

  Operators and agents should read the same status for a repository, and that
  status should be traceable to the exact commands that produced it. This
  projects health from the deterministic verification Attempts introduced in
  #244 rather than inferring it from agent activity.

  ## Computed, never stored

  Like `Custode.WorkReadModels`, this is recomputed from authoritative kernel
  rows on every call. Nothing is cached and nothing accepts health as write
  input, so there is no second mutable repository-health truth to drift from
  the evidence. Replaying an Artifact cannot duplicate or change health:
  health is a function of the newest finished verification Attempt per
  repository, and re-persisting identical evidence leaves that function's
  inputs unchanged.

  ## Five states, and why blocked is not failing

      unknown   no deterministic verification has ever been recorded
      stale     the newest verification no longer describes current truth
      passing   the newest verification rendered a pass
      failing   the newest verification ran and the repository failed it
      blocked   the verification could not render a verdict at all

  The distinction that earns its keep is `blocked` against `failing`. A
  timeout, an infrastructure error, a policy refusal, and a cancellation all
  mean the same thing: nobody knows whether this repository is healthy.
  Reporting that as `failing` would send someone to debug a test suite that
  never ran, and reporting it as `passing` would be a lie. It is a third
  thing, so it gets a third name.

  `stale` and `unknown` are likewise distinct from `failing`. Absent evidence
  is not adverse evidence.

  ## What makes a verification stale

  Two independent tests, checked in this order:

    * the verified revision is not the repository's current revision, when a
      caller supplies current revisions;
    * the verification is older than `:repository_health_stale_after_hours`
      (default 24).

  Revision mismatch is tested first and outranks the classification. A
  repository whose suite failed and which has since moved on reads `stale`,
  not `failing`, because the failure describes a revision nobody is running
  any more.

  Current revisions are an INPUT, never a lookup. Reading them here would
  mean a network call inside a projection and a guess when it failed, and
  "guessing" is exactly what #245 asks this to stop doing. With no revisions
  supplied, only the age test applies.

  ## Legacy history is unattributed, not invisible

  A verification Attempt whose Mission carries no `github_repository` target
  cannot be assigned to a repository. Those are reported under
  `:unattributed` rather than dropped, so the count of evidence the
  projection could not place is visible instead of silently missing.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Attempt, Mission, MissionTarget, Repo, WorkItem}

  @contract "custode.repository_health.v1"
  @target_kind "github_repository"
  @verification_kind "deterministic_verification"
  @stale_after_hours 24

  @type health :: String.t()

  @doc """
  Health for every repository target the fleet holds a Mission for.

  Options:

    * `:revisions` -- `%{"owner/name" => revision}` of current revisions. A
      supplied revision that differs from the verified one reads stale.
    * `:stale_after_seconds` -- override the age test.
    * `:now` -- evaluation time, for tests.
  """
  @spec list(keyword()) :: map()
  def list(options \\ []) do
    targets = repository_targets()
    newest = newest_verifications()

    items =
      targets
      |> Enum.map(&project(&1, Map.get(newest, &1.mission_id), options))
      |> Enum.sort_by(& &1.repository)

    %{
      contract: @contract,
      items: items,
      unattributed: unattributed(newest, targets)
    }
  end

  @doc "Health for one `\"owner/name\"`, or nil when no Mission targets it."
  @spec get(String.t(), keyword()) :: map() | nil
  def get(repository, options \\ []) when is_binary(repository) do
    list(options).items |> Enum.find(&(&1.repository == repository))
  end

  @doc """
  Pure health classification (#245), exposed for testing.

  Returns `{health, reason}`. `reason` names the test that decided, so a
  caller can tell an aged pass from a superseded one without re-deriving it.
  """
  @spec classify(map()) :: {health(), atom()}
  def classify(%{} = facts) do
    cond do
      is_nil(facts[:classification]) -> {"unknown", :no_verification}
      superseded?(facts) -> {"stale", :revision_moved}
      aged?(facts) -> {"stale", :verification_aged}
      facts[:classification] == "pass" -> {"passing", :verified}
      facts[:classification] == "test_failure" -> {"failing", :verification_failed}
      true -> {"blocked", :verdict_unavailable}
    end
  end

  # A revision test needs BOTH revisions. One missing is not a mismatch.
  defp superseded?(%{verified_revision: verified, current_revision: current})
       when is_binary(verified) and is_binary(current),
       do: verified != current

  defp superseded?(_facts), do: false

  defp aged?(%{verified_at: %DateTime{} = at, now: now, stale_after: stale_after}),
    do: DateTime.diff(now, at, :second) > stale_after

  defp aged?(_facts), do: false

  defp project(target, attempt, options) do
    evidence = evidence(attempt)

    facts = %{
      classification: evidence.outcome["classification"],
      verified_revision: get_in(evidence.outcome, ["workspace_revision", "revision"]),
      current_revision: options |> Keyword.get(:revisions, %{}) |> Map.get(target.display_name),
      verified_at: evidence.finished_at,
      now: Keyword.get(options, :now, DateTime.utc_now()),
      stale_after: stale_after(options)
    }

    {health, reason} = classify(facts)

    %{
      contract: @contract,
      repository: target.display_name,
      mission_id: target.mission_id,
      health: health,
      reason: reason,
      classification: facts.classification,
      revision: facts.verified_revision,
      verified_at: facts.verified_at,
      age_seconds: age_seconds(facts),
      recipe: evidence.recipe,
      commands: evidence.usage["commands"],
      duration_ms: evidence.usage["duration_ms"],
      failed_commands: evidence.error_details["failed_commands"] || [],
      # the traversal from a status to the evidence behind it
      work_item_id: evidence.work_item_id,
      attempt_id: evidence.attempt_id,
      artifacts: evidence.outcome["artifacts"] || %{}
    }
  end

  # Normalizing "no verification" into the same shape as a verification keeps
  # the projection flat instead of threading a nil check through every field.
  defp evidence(nil) do
    %{
      outcome: %{},
      recipe: nil,
      usage: %{},
      error_details: %{},
      work_item_id: nil,
      attempt_id: nil,
      finished_at: nil
    }
  end

  defp evidence(%Attempt{} = attempt) do
    outcome = attempt.outcome || %{}
    recipe = outcome["recipe"]

    %{
      outcome: outcome,
      recipe: recipe && Map.take(recipe, ["name", "version", "digest"]),
      usage: attempt.usage || %{},
      error_details: attempt.error_details || %{},
      work_item_id: attempt.work_item && attempt.work_item.work_item_id,
      attempt_id: attempt.attempt_id,
      finished_at: attempt.finished_at
    }
  end

  defp age_seconds(%{verified_at: %DateTime{} = at, now: now}),
    do: DateTime.diff(now, at, :second)

  defp age_seconds(_facts), do: nil

  defp stale_after(options) do
    Keyword.get_lazy(options, :stale_after_seconds, fn ->
      Application.get_env(:custode, :repository_health_stale_after_hours, @stale_after_hours) *
        3600
    end)
  end

  defp repository_targets do
    Repo.all(
      from(t in MissionTarget,
        join: m in Mission,
        on: m.id == t.mission_id,
        where: t.kind == ^@target_kind,
        select: %{display_name: t.display_name, mission_id: m.mission_id}
      )
    )
    |> Enum.uniq_by(& &1.display_name)
  end

  # The newest FINISHED verification per Mission. An unfinished Attempt is not
  # evidence of anything yet, and including it would let a queued run erase a
  # perfectly good result.
  defp newest_verifications do
    from(a in Attempt,
      join: w in WorkItem,
      on: w.id == a.work_item_id,
      join: m in Mission,
      on: m.id == w.mission_id,
      where: not is_nil(a.finished_at),
      where: fragment("json_extract(?, '$.kind') = ?", a.outcome, ^@verification_kind),
      preload: [work_item: w],
      select: {m.mission_id, a}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {mission_id, attempts} -> {mission_id, newest(attempts)} end)
  end

  # attempt_id breaks a same-timestamp tie, so the projection is stable rather
  # than dependent on row order.
  defp newest(attempts),
    do: Enum.max_by(attempts, &{DateTime.to_unix(&1.finished_at, :microsecond), &1.attempt_id})

  defp unattributed(newest, targets) do
    attributed = MapSet.new(targets, & &1.mission_id)

    orphans =
      newest
      |> Enum.reject(fn {mission_id, _attempt} -> MapSet.member?(attributed, mission_id) end)
      |> Enum.map(&elem(&1, 1))

    %{
      verifications: length(orphans),
      newest_at:
        orphans
        |> Enum.map(& &1.finished_at)
        |> Enum.max(DateTime, fn -> nil end)
    }
  end
end
