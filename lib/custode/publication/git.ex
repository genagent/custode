defmodule Custode.Publication.Git do
  @moduledoc """
  Effect-level idempotency for publishing one leased WorkItem branch.

  The branch is never force-pushed. Recovery accepts only a commit whose
  parent, subject, changed paths, and resulting workspace content match the
  verified publication input.
  """

  alias Custode.{WorkItems, WorkspaceLease, WorkspaceLeases}
  alias Custode.Workspace.Git

  @type outcome :: {:ok, map(), [map()]} | {:error, term()}

  def precondition(arguments, envelope) do
    with {:ok, lease} <- scope(arguments, envelope),
         {:ok, state} <- inspect_state(arguments, lease) do
      if state.workspace_expected? or state.local_published? or state.remote_published? do
        :ok
      else
        {:stale, state.reason || :publication_workspace_changed, observed(state)}
      end
    else
      {:error, reason} ->
        {:stale, reason, %{reason: inspect(reason)}}
    end
  end

  @spec publish(map()) :: outcome()
  def publish(arguments) do
    with %WorkspaceLease{} = lease <- WorkspaceLeases.get(value(arguments, :lease_id)),
         {:ok, state} <- inspect_state(arguments, lease) do
      publish_state(arguments, lease, state)
    else
      nil -> {:error, {:stale, :publication_lease_missing, %{}}}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile(arguments) do
    case WorkspaceLeases.get(value(arguments, :lease_id)) do
      %WorkspaceLease{} = lease -> reconcile_lease(arguments, lease)
      nil -> {:waiting, :publication_lease_missing}
    end
  end

  defp reconcile_lease(arguments, lease) do
    case inspect_state(arguments, lease) do
      {:ok, state} -> reconcile_state(arguments, lease, state)
      {:error, reason} -> {:waiting, reason}
    end
  end

  defp reconcile_state(arguments, lease, state) do
    cond do
      state.remote_published? ->
        reconcile_remote(arguments, lease, state)

      state.local_published? or state.workspace_expected? ->
        :retry

      true ->
        :retry
    end
  end

  defp reconcile_remote(arguments, lease, state) do
    case adopt_remote_if_needed(lease, state) do
      :ok ->
        result = result(arguments, state.remote_revision, "remote")
        {:ok, result, effects(result)}

      {:error, reason} ->
        {:waiting, reason}
    end
  end

  defp publish_state(arguments, lease, %{remote_published?: true} = state) do
    with :ok <- adopt_remote_if_needed(lease, state) do
      result = result(arguments, state.remote_revision, "remote")
      {:ok, result, effects(result)}
    end
  end

  defp publish_state(arguments, lease, %{local_published?: true, remote_revision: nil} = state) do
    expected_revision = state.local_revision

    with :ok <-
           Git.push(
             lease.repository_path,
             value(arguments, :remote),
             lease.branch,
             expected_revision
           ),
         {:ok, ^expected_revision} <-
           Git.remote_revision(
             lease.repository_path,
             value(arguments, :remote),
             lease.branch
           ) do
      result = result(arguments, expected_revision, "local")
      {:ok, result, effects(result)}
    else
      {:ok, observed} ->
        {:error,
         {:stale, :publication_remote_diverged,
          %{expected: state.local_revision, observed: observed}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_state(arguments, lease, %{workspace_expected?: true, remote_revision: nil}) do
    with {:ok, revision} <-
           Git.commit_all(lease.workspace_path, value(arguments, :commit_message)),
         :ok <-
           Git.push(
             lease.repository_path,
             value(arguments, :remote),
             lease.branch,
             revision
           ),
         {:ok, ^revision} <-
           Git.remote_revision(
             lease.repository_path,
             value(arguments, :remote),
             lease.branch
           ) do
      result = result(arguments, revision, "created")
      {:ok, result, effects(result)}
    else
      {:ok, observed} ->
        {:error,
         {:stale, :publication_remote_diverged, %{expected: :new_commit, observed: observed}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_state(_arguments, _lease, state) do
    {:error, {:stale, state.reason || :publication_state_diverged, observed(state)}}
  end

  defp inspect_state(arguments, lease) do
    remote = value(arguments, :remote)
    expected_revision = value(arguments, :expected_workspace_revision)
    expected_head = value(arguments, :expected_head_revision)

    with {:ok, refs} <- inspect_refs(lease, remote),
         {:ok, local_published?} <-
           published_commit?(lease, arguments, refs.local_revision, expected_head),
         {:ok, remote_published?} <-
           remote_published?(
             lease,
             arguments,
             remote,
             refs.remote_revision,
             expected_head
           ) do
      {:ok,
       publication_state(lease, refs, expected_revision, local_published?, remote_published?)}
    end
  end

  defp inspect_refs(lease, remote) do
    with :ok <- Git.ownership(lease.repository_path, lease.workspace_path),
         {:ok, branch} <- Git.branch(lease.workspace_path),
         {:ok, workspace_revision} <- Git.workspace_revision(lease.workspace_path),
         {:ok, local_revision} <- Git.revision(lease.workspace_path, "HEAD"),
         {:ok, remote_revision} <-
           Git.remote_revision(lease.repository_path, remote, lease.branch) do
      {:ok,
       %{
         branch: branch,
         workspace_revision: workspace_revision,
         local_revision: local_revision,
         remote_revision: remote_revision
       }}
    end
  end

  defp publication_state(lease, refs, expected_revision, local_published?, remote_published?) do
    valid_branch? = refs.branch == lease.branch
    workspace_expected? = refs.workspace_revision["revision"] == expected_revision

    state = %{
      branch: refs.branch,
      workspace_revision: refs.workspace_revision,
      workspace_expected?: workspace_expected? and valid_branch?,
      local_revision: refs.local_revision,
      local_published?: local_published? and valid_branch?,
      remote_revision: refs.remote_revision,
      remote_published?: remote_published? and valid_branch?
    }

    Map.put(state, :reason, state_reason(state, valid_branch?))
  end

  defp state_reason(_state, false), do: :publication_branch_changed

  defp state_reason(%{remote_revision: revision, remote_published?: false}, true)
       when is_binary(revision),
       do: :publication_remote_diverged

  defp state_reason(
         %{workspace_expected?: false, local_published?: false, remote_published?: false},
         true
       ),
       do: :publication_workspace_changed

  defp state_reason(_state, true), do: nil

  defp published_commit?(lease, arguments, revision, expected_head) do
    if revision == expected_head do
      {:ok, false}
    else
      commit_matches?(lease, arguments, revision, expected_head)
    end
  end

  defp remote_published?(_lease, _arguments, _remote, nil, _expected_head), do: {:ok, false}

  defp remote_published?(lease, arguments, remote, revision, expected_head) do
    case commit_matches?(lease, arguments, revision, expected_head) do
      {:ok, matches?} ->
        {:ok, matches?}

      {:error, _reason} ->
        with :ok <- Git.fetch_commit(lease.repository_path, remote, revision) do
          commit_matches?(lease, arguments, revision, expected_head)
        end
    end
  end

  defp commit_matches?(lease, arguments, revision, expected_head) do
    with {:ok, parent} <- Git.commit_parent(lease.repository_path, revision),
         {:ok, subject} <- Git.commit_subject(lease.repository_path, revision),
         {:ok, changed_files} <-
           Git.changed_files_between(lease.repository_path, expected_head, revision),
         {:ok, workspace_matches?} <- Git.matches_commit?(lease.workspace_path, revision) do
      {:ok,
       parent == expected_head and
         subject == value(arguments, :commit_message) and
         changed_files == value(arguments, :expected_changed_files) and
         workspace_matches?}
    end
  end

  defp adopt_remote_if_needed(lease, state) do
    if state.local_revision == state.remote_revision and state.local_published? do
      :ok
    else
      Git.reset_hard(lease.workspace_path, state.remote_revision)
    end
  end

  defp scope(arguments, envelope) do
    lease_id = value(arguments, :lease_id)
    work_item_id = value(arguments, :work_item_id)
    attempt_id = value(arguments, :attempt_id)
    expected_version = value(arguments, :expected_work_item_version)

    with work_item when not is_nil(work_item) <- WorkItems.get(work_item_id),
         %WorkspaceLease{} = lease <- WorkspaceLeases.get(lease_id),
         true <- envelope.work_item_id == work_item_id,
         true <- envelope.attempt_id == attempt_id,
         true <- value(envelope.expected_versions, :work_item) == expected_version,
         true <- work_item.version == expected_version,
         true <- work_item.state == "active",
         true <- work_item.phase == "publishing",
         true <- work_item.active_attempt_id == attempt_id,
         true <- lease.state == "active",
         true <- lease.work_item.work_item_id == work_item_id,
         true <- lease.repository_path == value(arguments, :repository_path),
         true <- lease.workspace_path == value(arguments, :workspace_path),
         true <- lease.branch == value(arguments, :branch) do
      {:ok, lease}
    else
      nil -> {:error, :publication_scope_missing}
      false -> {:error, :publication_scope_changed}
    end
  end

  defp result(arguments, revision, source) do
    %{
      work_item_id: value(arguments, :work_item_id),
      lease_id: value(arguments, :lease_id),
      repository: value(arguments, :repository),
      branch: value(arguments, :branch),
      remote: value(arguments, :remote),
      commit_sha: revision,
      source: source
    }
  end

  defp effects(result) do
    [
      %{
        type: "git_branch_published",
        work_item_id: result.work_item_id,
        repository: result.repository,
        branch: result.branch,
        commit_sha: result.commit_sha,
        remote: result.remote
      }
    ]
  end

  defp observed(state) do
    %{
      branch: state.branch,
      workspace_revision: state.workspace_revision["revision"],
      local_revision: state.local_revision,
      remote_revision: state.remote_revision,
      local_published: state.local_published?,
      remote_published: state.remote_published?
    }
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
