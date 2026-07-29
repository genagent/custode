defmodule Custode.PublicationContext do
  @moduledoc """
  Reproducible publication input pinned to successful verification evidence.
  """

  alias Custode.{
    Attempt,
    Attempts,
    ContextBundles,
    WorkspaceLease,
    WorkspaceLeases
  }

  alias Custode.Workspace.Git

  @doc "Compile or reuse the exact input for one publication Attempt."
  def compile(routine, work_item, %WorkspaceLease{} = lease, options \\ []) do
    with %Attempt{} = verification <- verification_attempt(work_item.work_item_id),
         {:ok, source_body} <- ContextBundles.body(verification.context_bundle),
         :ok <- Git.ownership(lease.repository_path, lease.workspace_path),
         {:ok, workspace_revision} <- Git.workspace_revision(lease.workspace_path),
         :ok <- verified_revision(verification, workspace_revision),
         true <- workspace_revision["changed_files"] != [],
         {:ok, base_branch} <- base_branch(lease),
         {:ok, publication} <-
           publication_input(
             work_item,
             lease,
             workspace_revision,
             base_branch
           ),
         body <-
           publication_body(source_body, verification, lease, workspace_revision, publication),
         {:ok, {_status, bundle}} <-
           ContextBundles.create(
             work_item.work_item_id,
             body,
             artifact_options(options,
               provenance: %{
                 compiler: "publication_context",
                 purpose: "publication",
                 legacy_routine_id: routine.id,
                 source_attempt_id: verification.attempt_id,
                 workspace_lease_id: lease.lease_id,
                 workspace_revision: workspace_revision["revision"],
                 branch: lease.branch
               }
             )
           ) do
      {:ok,
       %{
         bundle: bundle,
         body: body,
         lease: lease,
         verification_attempt: verification,
         workspace_revision: workspace_revision,
         publication: publication
       }}
    else
      nil -> {:error, {:publication_verification_attempt_missing, work_item.work_item_id}}
      false -> {:error, :publication_has_no_changes}
      {:error, _reason} = error -> error
    end
  end

  defp verification_attempt(work_item_id) do
    work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(fn attempt ->
      attempt.state == "succeeded" and
        get_in(attempt.provenance || %{}, ["purpose"]) == "github_issue_verification" and
        get_in(attempt.outcome || %{}, ["proposal", "phase"]) == "publication_ready"
    end)
  end

  defp verified_revision(verification, observed) do
    expected = get_in(verification.outcome || %{}, ["workspace_revision", "revision"])

    if expected == observed["revision"] do
      :ok
    else
      {:error,
       {:publication_workspace_changed, %{expected: expected, observed: observed["revision"]}}}
    end
  end

  defp publication_input(work_item, lease, workspace_revision, base_branch) do
    source = Custode.WorkItems.latest_source_snapshot(work_item.work_item_id)

    with %{} = source <- source,
         %{} = issue <- source["issue"],
         repository when is_binary(repository) <- source["canonical_name"],
         number when is_integer(number) <- issue["number"],
         title when is_binary(title) and title != "" <- issue["title"] do
      {:ok,
       %{
         "repository" => repository,
         "remote" => "origin",
         "branch" => lease.branch,
         "base_branch" => base_branch,
         "expected_workspace_revision" => workspace_revision["revision"],
         "expected_head_revision" => workspace_revision["head_revision"],
         "expected_changed_files" => workspace_revision["changed_files"],
         "commit_message" => title,
         "title" => title,
         "body" =>
           "Closes ##{number}.\n\nPublished by Custode WorkItem `#{work_item.work_item_id}`.",
         "issue_number" => number,
         "issue_revision" => source["revision"]
       }}
    else
      _invalid -> {:error, :publication_source_snapshot_invalid}
    end
  end

  defp base_branch(%{base_ref: base_ref, repository_path: repository_path}) do
    case base_ref do
      "HEAD" -> Git.branch(repository_path)
      "refs/heads/" <> branch -> {:ok, branch}
      branch when is_binary(branch) and branch != "" -> {:ok, branch}
      _missing -> {:error, :publication_base_branch_missing}
    end
  end

  defp publication_body(source_body, verification, lease, workspace_revision, publication) do
    source_body
    |> Map.put(
      "recipe",
      source_body
      |> Map.get("recipe", %{})
      |> Map.put("publication", %{
        "name" => "github_draft_pr",
        "version" => "github_issue_publication_v1",
        "operations" => ["git.publish_branch", "github.open_pr"]
      })
    )
    |> Map.put(
      "prior_evidence",
      Map.get(source_body, "prior_evidence", []) ++ [attempt_evidence(verification)]
    )
    |> Map.put(
      "workspace_revision",
      lease
      |> WorkspaceLeases.render()
      |> Map.merge(workspace_revision)
    )
    |> Map.put("publication", publication)
    |> Map.put("capabilities", %{
      "tools" => [],
      "operations" => ["git.publish_branch", "github.open_pr"]
    })
    |> Map.put("output_contract", %{
      "kind" => "github_draft_publication",
      "artifacts" => ["branch", "commit", "pull_request"]
    })
  end

  defp attempt_evidence(attempt) do
    %{
      "attempt_id" => attempt.attempt_id,
      "context_bundle_id" => attempt.context_bundle.context_bundle_id,
      "context_digest" => attempt.context_digest,
      "state" => attempt.state,
      "usage" => attempt.usage,
      "outcome" => attempt.outcome,
      "finished_at" => attempt.finished_at && DateTime.to_iso8601(attempt.finished_at)
    }
  end

  defp artifact_options(options, provenance: provenance) do
    [
      artifact_dir: Keyword.get(options, :artifact_dir),
      provenance: provenance,
      retention: %{until: "work_item_terminal"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
