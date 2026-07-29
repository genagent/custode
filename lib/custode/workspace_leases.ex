defmodule Custode.WorkspaceLeases do
  @moduledoc """
  Restart-safe ownership and preparation of contained repository worktrees.

  A durable `acquiring` row is claimed before Git creates a directory.
  Repeating acquisition inspects and completes the same lease. Expiry marks a
  lease stale and retained; only an explicit release with proven Git ownership
  may remove the worktree.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Artifacts, Attempts, Repo, WorkItems, WorkspaceLease}
  alias Custode.Workspace.Git

  @live_states ~w(acquiring active)
  @terminal_attempt_states ~w(succeeded partial blocked failed cancelled)
  @terminal_work_states ~w(completed cancelled)
  @default_ttl_seconds 3_600

  def get(lease_id) do
    WorkspaceLease
    |> Repo.get_by(lease_id: lease_id)
    |> preload()
  end

  def get_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        nil

      work_item ->
        from(lease in WorkspaceLease,
          where: lease.work_item_id == ^work_item.id,
          order_by: [desc: lease.inserted_at],
          limit: 1
        )
        |> Repo.one()
        |> preload()
    end
  end

  def list_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        []

      work_item ->
        from(lease in WorkspaceLease,
          where: lease.work_item_id == ^work_item.id,
          order_by: [asc: lease.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&preload/1)
    end
  end

  def acquire(attrs, options \\ []) when is_map(attrs) or is_list(attrs) do
    attrs = atomize(attrs)

    case validate_acquisition(attrs, options) do
      {:ok, prepared} ->
        with {:ok, status, lease} <- claim(prepared, options),
             {:ok, lease} <- prepare(lease, options) do
          {:ok, {status, lease}}
        end

      {:error, {:base_revision_changed, observed}} ->
        stale_existing_lease(attrs[:work_item_id], observed)

      {:error, _reason} = error ->
        error
    end
  end

  def prepare_attempt(attempt_id, attrs, options \\ []) do
    case Attempts.get(attempt_id) do
      %{state: state} = attempt when state in ~w(succeeded partial blocked failed cancelled) ->
        case lease_from_outcome(attempt.outcome) do
          %WorkspaceLease{} = lease -> {:ok, %{attempt: attempt, lease: lease}}
          nil -> {:error, {:attempt_terminal, state}}
        end

      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      _queued_or_running ->
        with {:ok, _running} <-
               Attempts.start(attempt_id, %{oban_job_id: options[:oban_job_id]}),
             {:ok, {_status, lease}} <-
               acquire(Map.put(Map.new(attrs), :attempt_id, attempt_id), options),
             {:ok, finished} <-
               Attempts.finish(attempt_id, %{
                 state: "succeeded",
                 usage: %{duration_ms: Keyword.get(options, :duration_ms, 0)},
                 outcome: %{
                   kind: "workspace_prepared",
                   workspace_lease: render(lease),
                   proposal: %{
                     state: "waiting",
                     phase: "compiling_context",
                     waiting_condition: %{
                       kind: "reconciler",
                       name: "context_compilation"
                     },
                     evidence: %{workspace_lease: render(lease)}
                   }
                 }
               }) do
          {:ok, %{attempt: finished, lease: lease}}
        end
    end
  end

  def heartbeat(lease_id, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    ttl = Keyword.get(options, :ttl_seconds, @default_ttl_seconds)
    git = Keyword.get(options, :git, Git)

    Repo.transaction(
      fn ->
        lease = lock_lease!(lease_id)

        if lease.state != "active", do: Repo.rollback({:lease_not_active, lease.state})

        case git.revision(lease.repository_path, lease.base_ref) do
          {:ok, revision} when revision == lease.expected_base_revision ->
            update!(
              lease,
              heartbeat_at: now,
              expires_at: DateTime.add(now, ttl, :second),
              observed_base_revision: revision
            )

          {:ok, revision} ->
            stale!(lease, revision, "base_revision_changed")

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  def reconcile(now \\ DateTime.utc_now()) do
    Repo.transaction(
      fn ->
        leases =
          Repo.all(
            from(lease in WorkspaceLease,
              join: work_item in assoc(lease, :work_item),
              join: attempt in assoc(lease, :attempt),
              where:
                lease.state in ^@live_states and
                  (lease.expires_at <= ^now or work_item.state in ^@terminal_work_states or
                     (lease.state == "acquiring" and
                        attempt.state in ^@terminal_attempt_states)),
              select: {lease, work_item.state, attempt.state}
            )
          )

        Enum.map(leases, fn {lease, work_state, attempt_state} ->
          update!(lease,
            state: "stale",
            cleanup_state: "retained",
            cleanup_error: %{
              code: reconciliation_code(lease, work_state, attempt_state, now)
            }
          )
        end)
      end,
      mode: :immediate
    )
    |> case do
      {:ok, leases} -> {:ok, Enum.map(leases, &preload/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile_expired(now \\ DateTime.utc_now()), do: reconcile(now)

  def reconcile! do
    case reconcile() do
      {:ok, _leases} -> :ok
      {:error, reason} -> raise "workspace lease reconciliation failed: #{inspect(reason)}"
    end
  end

  def release(lease_id, options \\ []) do
    cleanup? = Keyword.get(options, :cleanup, false)
    git = Keyword.get(options, :git, Git)
    now = Keyword.get(options, :now, DateTime.utc_now())

    with %WorkspaceLease{} = lease <- get(lease_id),
         {:ok, cleanup_state} <- cleanup(lease, cleanup?, git) do
      persist_release(lease_id, cleanup_state, now)
    else
      nil -> {:error, {:unknown_workspace_lease, lease_id}}
      {:error, reason} -> record_cleanup_failure(lease_id, reason)
    end
  end

  def render(%WorkspaceLease{} = lease) do
    lease = preload(lease)

    %{
      lease_id: lease.lease_id,
      mission_id: lease.mission.mission_id,
      work_item_id: lease.work_item.work_item_id,
      attempt_id: lease.attempt.attempt_id,
      repository_id: lease.repository_id,
      repository_path: lease.repository_path,
      workspace_identity: lease.workspace_identity,
      workspace_path: lease.workspace_path,
      branch: lease.branch,
      base_ref: lease.base_ref,
      expected_base_revision: lease.expected_base_revision,
      observed_base_revision: lease.observed_base_revision,
      landing_scope: lease.landing_scope,
      state: lease.state,
      cleanup_state: lease.cleanup_state,
      acquired_at: iso8601(lease.acquired_at),
      heartbeat_at: iso8601(lease.heartbeat_at),
      expires_at: iso8601(lease.expires_at),
      prepared_at: iso8601(lease.prepared_at),
      released_at: iso8601(lease.released_at),
      cleanup_error: lease.cleanup_error
    }
  end

  defp validate_acquisition(attrs, options) do
    git = Keyword.get(options, :git, Git)

    with {:ok, work_item} <- fetch_work_item(attrs[:work_item_id]),
         {:ok, attempt} <- fetch_attempt(attrs[:attempt_id]),
         :ok <- validate_attempt(attempt, work_item),
         {:ok, repository_id} <- validate_target(work_item, attrs[:repository_id]),
         {:ok, paths} <- validate_paths(attrs, work_item, options),
         {:ok, observed} <- validate_repository(attrs, paths.repository_path, git) do
      {:ok, acquisition_attrs(attrs, work_item, attempt, repository_id, paths, observed)}
    end
  end

  defp claim(attrs, options) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    ttl = Keyword.get(options, :ttl_seconds, @default_ttl_seconds)

    Repo.transaction(fn -> claim_locked(attrs, now, ttl) end, mode: :immediate)
    |> case do
      {:ok, {status, lease}} -> {:ok, status, preload(lease)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(%WorkspaceLease{state: "active"} = lease, _options), do: {:ok, lease}

  defp prepare(%WorkspaceLease{state: "acquiring"} = lease, options) do
    git = Keyword.get(options, :git, Git)

    with {:ok, observed} <- git.revision(lease.repository_path, lease.base_ref),
         :ok <- expected_revision(observed, lease.expected_base_revision),
         {:ok, evidence} <-
           git.prepare(
             lease.repository_path,
             lease.workspace_path,
             lease.branch,
             lease.expected_base_revision
           ),
         :ok <- after_worktree(options, lease),
         {:ok, artifact} <- preparation_artifact(lease, evidence, options) do
      now = Keyword.get(options, :now, DateTime.utc_now())

      lease
      |> WorkspaceLease.update_changeset(%{
        state: "active",
        observed_base_revision: observed,
        prepared_at: now,
        provenance: Map.put(lease.provenance, "preparation_artifact_id", artifact.artifact_id)
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, preload(updated)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:base_revision_changed, observed}} ->
        mark_stale(lease, observed, "base_revision_changed")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp preparation_artifact(lease, evidence, options) do
    artifact_id = "workspace-preparation:#{lease.lease_id}"

    case Artifacts.get(artifact_id) do
      nil ->
        body =
          Jason.encode!(%{
            lease_id: lease.lease_id,
            repository_id: lease.repository_id,
            workspace_identity: lease.workspace_identity,
            workspace_path: lease.workspace_path,
            branch: lease.branch,
            base_ref: lease.base_ref,
            expected_base_revision: lease.expected_base_revision,
            evidence: evidence
          })

        Artifacts.put(
          lease.work_item.work_item_id,
          body,
          %{
            artifact_id: artifact_id,
            producer_attempt_id: lease.attempt.attempt_id,
            kind: "workspace_preparation",
            media_type: "application/json",
            provenance: %{lease_id: lease.lease_id},
            retention: %{until: "work_item_terminal"}
          },
          artifact_dir: Keyword.get(options, :artifact_dir, default_artifact_dir())
        )

      artifact ->
        {:ok, artifact}
    end
  end

  defp cleanup(_lease, false, _git), do: {:ok, "retained"}

  defp cleanup(%WorkspaceLease{cleanup_state: "cleaned"}, true, _git), do: {:ok, "cleaned"}

  defp cleanup(lease, true, git) do
    case git.remove(lease.repository_path, lease.workspace_path) do
      :ok -> {:ok, "cleaned"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_release(lease_id, cleanup_state, now) do
    Repo.transaction(
      fn ->
        current = lock_lease!(lease_id)

        update!(current,
          state: "released",
          cleanup_state: cleanup_state,
          released_at: current.released_at || now,
          cleanup_error: nil
        )
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  defp record_cleanup_failure(lease_id, reason) do
    case get(lease_id) do
      nil ->
        {:error, {:unknown_workspace_lease, lease_id}}

      lease ->
        lease
        |> WorkspaceLease.update_changeset(%{
          state: "cleanup_failed",
          cleanup_state: "failed",
          cleanup_error: %{reason: inspect(reason)}
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:error, {:cleanup_failed, reason, preload(updated)}}
          {:error, update_reason} -> {:error, update_reason}
        end
    end
  end

  defp mark_stale(lease, observed, code) do
    lease
    |> WorkspaceLease.update_changeset(%{
      state: "stale",
      cleanup_state: "retained",
      observed_base_revision: observed,
      cleanup_error: %{code: code}
    })
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:error, {:stale, code, preload(updated)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_existing_lease(work_item_id, observed) do
    case fetch_work_item(work_item_id) do
      {:ok, work_item} ->
        case live_for_work_item(work_item.id) do
          %WorkspaceLease{} = lease ->
            mark_stale(lease, observed, "base_revision_changed")

          nil ->
            {:error, {:base_revision_changed, observed}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp stale!(lease, observed, code) do
    updated =
      update!(lease,
        state: "stale",
        cleanup_state: "retained",
        observed_base_revision: observed,
        cleanup_error: %{code: code}
      )

    Repo.rollback({:stale, code, preload(updated)})
  end

  defp live_for_work_item(work_item_id) do
    Repo.one(
      from(lease in WorkspaceLease,
        where: lease.work_item_id == ^work_item_id and lease.state in ^@live_states
      )
    )
  end

  defp claim_locked(attrs, now, ttl) do
    case live_for_work_item(attrs.work_item_id) do
      %WorkspaceLease{} = lease ->
        ensure_same!(lease, attrs)
        {:existing, lease}

      nil ->
        insert_claim(attrs, now, ttl)
    end
  end

  defp insert_claim(attrs, now, ttl) do
    create_attrs =
      Map.merge(attrs, %{
        state: "acquiring",
        cleanup_state: "pending",
        acquired_at: now,
        heartbeat_at: now,
        expires_at: DateTime.add(now, ttl, :second)
      })

    case create_attrs |> WorkspaceLease.create_changeset() |> Repo.insert() do
      {:ok, lease} -> {:created, lease}
      {:error, changeset} -> Repo.rollback(lease_conflict(changeset))
    end
  end

  defp fetch_work_item(work_item_id) when is_binary(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil -> {:error, {:unknown_work_item, work_item_id}}
      work_item -> {:ok, work_item}
    end
  end

  defp fetch_work_item(work_item_id), do: {:error, {:unknown_work_item, work_item_id}}

  defp fetch_attempt(attempt_id) when is_binary(attempt_id) do
    case Attempts.get(attempt_id) do
      nil -> {:error, {:unknown_attempt, attempt_id}}
      attempt -> {:ok, attempt}
    end
  end

  defp fetch_attempt(attempt_id), do: {:error, {:unknown_attempt, attempt_id}}

  defp validate_attempt(attempt, work_item) do
    cond do
      attempt.work_item.id != work_item.id ->
        {:error, :attempt_work_item_mismatch}

      attempt.executor_kind != "deterministic" ->
        {:error, :deterministic_attempt_required}

      attempt.state != "running" ->
        {:error, :attempt_not_running}

      not attempt_owns_work_version?(attempt, work_item) ->
        {:error, :work_item_version_changed}

      true ->
        :ok
    end
  end

  defp attempt_owns_work_version?(attempt, work_item) do
    attempt.expected_work_item_version == work_item.version or
      (work_item.state == "active" and work_item.active_attempt_id == attempt.attempt_id and
         attempt.expected_work_item_version + 1 == work_item.version)
  end

  defp validate_target(work_item, repository_id)
       when is_binary(repository_id) and repository_id != "" do
    if mission_target?(work_item.mission, repository_id),
      do: {:ok, repository_id},
      else: {:error, :repository_target_mismatch}
  end

  defp validate_target(_work_item, _repository_id), do: {:error, :repository_id_required}

  defp validate_paths(attrs, work_item, options) do
    with {:ok, repository_path} <- repository_path(attrs[:repository_path]),
         {:ok, root} <-
           expanded_path(
             Keyword.get(options, :workspace_root, default_root(repository_path)),
             :workspace_root_required
           ),
         {:ok, workspace_path} <-
           expanded_path(
             attrs[:workspace_path] || default_path(root, work_item.work_item_id),
             :workspace_path_required
           ),
         :ok <- validate_containment(root, workspace_path) do
      {:ok, %{repository_path: repository_path, root: root, workspace_path: workspace_path}}
    end
  end

  defp repository_path(path) do
    with {:ok, expanded} <- expanded_path(path, :repository_path_missing),
         true <- File.dir?(expanded) do
      {:ok, expanded}
    else
      false -> {:error, :repository_path_missing}
      {:error, _reason} = error -> error
    end
  end

  defp expanded_path(path, _error) when is_binary(path) and path != "",
    do: {:ok, Path.expand(path)}

  defp expanded_path(_path, error), do: {:error, error}

  defp validate_containment(root, workspace_path) do
    with {:ok, canonical_root} <- canonical_path(root),
         {:ok, canonical_workspace} <- canonical_path(workspace_path),
         true <- contained?(canonical_root, canonical_workspace) do
      :ok
    else
      _outside_or_unresolved -> {:error, :workspace_path_not_contained}
    end
  end

  defp validate_repository(attrs, repository_path, git) do
    base_ref = attrs[:base_ref] || "HEAD"

    with :ok <- expected_revision_present(attrs[:expected_base_revision]),
         :ok <- git.tracked_clean?(repository_path),
         {:ok, observed} <- git.revision(repository_path, base_ref),
         :ok <- expected_revision(observed, attrs[:expected_base_revision]) do
      {:ok, observed}
    end
  end

  defp expected_revision_present(revision) when is_binary(revision) and revision != "", do: :ok
  defp expected_revision_present(_revision), do: {:error, :expected_base_revision_required}

  defp acquisition_attrs(attrs, work_item, attempt, repository_id, paths, observed) do
    %{
      lease_id: attrs[:lease_id] || Ecto.UUID.generate(),
      mission_id: work_item.mission_id,
      work_item_id: work_item.id,
      attempt_id: attempt.id,
      repository_id: repository_id,
      repository_path: paths.repository_path,
      workspace_identity: attrs[:workspace_identity] || "work-item:#{work_item.work_item_id}",
      workspace_path: paths.workspace_path,
      branch: attrs[:branch] || branch(work_item.work_item_id),
      base_ref: attrs[:base_ref] || "HEAD",
      expected_base_revision: attrs[:expected_base_revision],
      observed_base_revision: observed,
      landing_scope: attrs[:landing_scope] || "github_repository:#{repository_id}",
      provenance: attrs[:provenance] || %{}
    }
  end

  defp ensure_same!(lease, attrs) do
    fields =
      ~w(attempt_id repository_id repository_path workspace_path branch base_ref expected_base_revision landing_scope)a

    differences =
      Enum.filter(fields, &(Map.get(lease, &1) != Map.get(attrs, &1)))

    if differences != [], do: Repo.rollback({:workspace_lease_conflict, differences})
  end

  defp lease_conflict(changeset) do
    if Enum.any?(changeset.errors, fn
         {_field, {_message, options}} -> options[:constraint] == :unique
       end) do
      :workspace_scope_owned
    else
      changeset
    end
  end

  defp mission_target?(mission, repository_id) do
    mission
    |> Repo.preload(:targets)
    |> Map.fetch!(:targets)
    |> Enum.any?(&(&1.kind == "github_repository" and &1.external_id == repository_id))
  end

  defp lease_from_outcome(outcome) do
    case get_in(outcome || %{}, ["workspace_lease", "lease_id"]) do
      lease_id when is_binary(lease_id) -> get(lease_id)
      _missing -> nil
    end
  end

  defp reconciliation_code(lease, work_state, attempt_state, now) do
    cond do
      DateTime.compare(lease.expires_at, now) != :gt -> "lease_expired"
      work_state in @terminal_work_states -> "work_item_terminal"
      attempt_state in @terminal_attempt_states -> "acquisition_attempt_terminal"
    end
  end

  defp expected_revision(revision, revision), do: :ok
  defp expected_revision(observed, _expected), do: {:error, {:base_revision_changed, observed}}

  defp contained?(root, path) do
    relative = Path.relative_to(path, root)

    Path.type(relative) == :relative and
      relative != "." and relative != ".." and not String.starts_with?(relative, "../")
  end

  defp canonical_path(path) do
    {ancestor, suffix} = existing_ancestor(Path.expand(path), [])

    case System.cmd("pwd", ["-P"], cd: ancestor, stderr_to_stdout: true) do
      {physical, 0} -> {:ok, Path.join([String.trim(physical) | suffix])}
      {_output, _status} -> {:error, :canonical_path_unavailable}
    end
  end

  defp existing_ancestor(path, suffix) do
    if File.dir?(path) do
      {path, suffix}
    else
      existing_ancestor(Path.dirname(path), [Path.basename(path) | suffix])
    end
  end

  defp after_worktree(options, lease) do
    case Keyword.get(options, :after_worktree, fn _lease -> :ok end).(lease) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp default_root(repository_path), do: Path.join(repository_path, ".claude/worktrees")

  defp default_path(root, work_item_id),
    do: Path.join(root, String.replace(work_item_id, "-", ""))

  defp branch(work_item_id), do: "custode/work-#{String.replace(work_item_id, "-", "")}"

  defp default_artifact_dir,
    do: Custode.Home.resolve_in(&Custode.Home.data_dir/0, "artifacts/workspace_preparations")

  defp lock_lease!(lease_id) do
    case Repo.one(from(lease in WorkspaceLease, where: lease.lease_id == ^lease_id)) do
      nil -> Repo.rollback({:unknown_workspace_lease, lease_id})
      lease -> lease
    end
  end

  defp update!(lease, attrs) do
    lease
    |> WorkspaceLease.update_changeset(Map.new(attrs))
    |> Repo.update!()
  end

  defp unwrap({:ok, lease}), do: {:ok, preload(lease)}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp preload(nil), do: nil
  defp preload(lease), do: Repo.preload(lease, [:mission, :work_item, :attempt])

  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)

  defp atomize(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end
end
