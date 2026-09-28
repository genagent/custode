defmodule Custode.Publication.GitHub do
  @moduledoc """
  Policy-preserving draft pull-request creation and effect reconciliation.

  Every read and write stays behind the served repository process. Existing
  matching pull requests are successful replay; a reused branch at another
  head is stale.
  """

  alias Custode.{Repository, WorkItems, WorkspaceLease, WorkspaceLeases}
  alias Custode.Workspace.Git

  def precondition(arguments, envelope) do
    with {:ok, lease} <- scope(arguments, envelope),
         {:ok, observed_head} <-
           Git.remote_revision(
             lease.repository_path,
             value(arguments, :remote),
             lease.branch
           ),
         true <- observed_head == value(arguments, :expected_head_sha) do
      :ok
    else
      {:error, reason} ->
        {:stale, reason, %{reason: inspect(reason)}}

      false ->
        {:stale, :publication_remote_head_changed, observed(arguments)}
    end
  end

  def open(arguments, actor) do
    case find(arguments) do
      {:ok, pull_request} ->
        success(arguments, pull_request, "existing")

      :missing ->
        create(arguments, actor)

      {:stale, reason, observed} ->
        {:error, {:stale, reason, observed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reconcile(arguments) do
    case find(arguments) do
      {:ok, pull_request} ->
        result = result(arguments, pull_request, "reconciled")
        {:ok, result, effects(result)}

      :missing ->
        :retry

      {:stale, _reason, _observed} ->
        :retry

      {:error, reason} ->
        {:waiting, reason}
    end
  end

  defp create(arguments, actor) do
    attrs = %{
      title: value(arguments, :title),
      head: value(arguments, :head_branch),
      base: value(arguments, :base_branch),
      body: value(arguments, :body)
    }

    with {:ok, created} <- Repository.open_pr(value(arguments, :repository), attrs, actor),
         {:ok, pull_request} <- created_pull_request(arguments, created) do
      success(arguments, pull_request, "created")
    end
  end

  defp created_pull_request(arguments, created) do
    number = value(created, :number)

    if is_integer(number) do
      case Repository.view_pr(value(arguments, :repository), number) do
        {:ok, pull_request} ->
          validate_created(arguments, pull_request)

        {:error, _reason} ->
          validate_created(arguments, %{
            number: number,
            title: value(arguments, :title),
            state: "open",
            draft: true,
            base: value(arguments, :base_branch),
            head: value(arguments, :head_branch),
            head_sha: value(arguments, :expected_head_sha),
            url: value(created, :html_url) || value(created, :url)
          })
      end
    else
      {:error, :publication_pull_request_identity_missing}
    end
  end

  defp validate_created(arguments, pull_request) do
    if matching_open?(pull_request, arguments) do
      {:ok, pull_request}
    else
      {:error,
       {:stale, :publication_pull_request_changed,
        %{pull_request: normalize_pull_request(pull_request)}}}
    end
  end

  defp find(arguments) do
    case Repository.list_prs(value(arguments, :repository), %{state: "all"}) do
      {:ok, pull_requests} -> find_candidate(arguments, pull_requests)
      {:error, _reason} = error -> error
    end
  end

  defp find_candidate(arguments, pull_requests) do
    candidates =
      Enum.filter(
        pull_requests,
        &(value(&1, :head) == value(arguments, :head_branch))
      )

    case Enum.find(candidates, &matching_open?(&1, arguments)) do
      nil -> missing_candidate(candidates)
      pull_request -> {:ok, pull_request}
    end
  end

  defp missing_candidate([]), do: :missing

  defp missing_candidate(candidates) do
    {:stale, :publication_pull_request_diverged,
     %{pull_requests: Enum.map(candidates, &normalize_pull_request/1)}}
  end

  defp matching_open?(pull_request, arguments) do
    value(pull_request, :state) == "open" and
      value(pull_request, :head) == value(arguments, :head_branch) and
      value(pull_request, :base) == value(arguments, :base_branch) and
      value(pull_request, :head_sha) == value(arguments, :expected_head_sha)
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
         true <- lease.branch == value(arguments, :head_branch) do
      {:ok, lease}
    else
      nil -> {:error, :publication_scope_missing}
      false -> {:error, :publication_scope_changed}
    end
  end

  defp success(arguments, pull_request, source) do
    result = result(arguments, pull_request, source)
    {:ok, result, effects(result)}
  end

  defp result(arguments, pull_request, source) do
    %{
      work_item_id: value(arguments, :work_item_id),
      repository: value(arguments, :repository),
      number: value(pull_request, :number),
      url: value(pull_request, :url) || value(pull_request, :html_url),
      state: value(pull_request, :state),
      draft: value(pull_request, :draft),
      base_branch: value(pull_request, :base),
      head_branch: value(pull_request, :head),
      head_sha: value(pull_request, :head_sha),
      source: source
    }
  end

  defp effects(result) do
    [
      %{
        type: "github_pull_request_opened",
        work_item_id: result.work_item_id,
        repository: result.repository,
        number: result.number,
        url: result.url,
        head_branch: result.head_branch,
        head_sha: result.head_sha,
        draft: result.draft
      }
    ]
  end

  defp observed(arguments) do
    %{
      repository: value(arguments, :repository),
      branch: value(arguments, :head_branch),
      expected_head_sha: value(arguments, :expected_head_sha)
    }
  end

  defp normalize_pull_request(pull_request) do
    %{
      number: value(pull_request, :number),
      state: value(pull_request, :state),
      draft: value(pull_request, :draft),
      base: value(pull_request, :base),
      head: value(pull_request, :head),
      head_sha: value(pull_request, :head_sha),
      url: value(pull_request, :url)
    }
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
