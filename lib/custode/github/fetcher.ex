defmodule Custode.GitHub.Fetcher do
  @moduledoc """
  The real repo-overview fetch: one gh_ex GraphQL query for issues + PRs.

  Token resolution: `GITHUB_TOKEN` if set, else `gh auth token` (run once
  and kept in `:persistent_term` -- routine refreshes must not shell out).
  """

  @behaviour Custode.GitHub.FetcherBehaviour

  @query """
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      defaultBranchRef {
        name
        target {
          ... on Commit {
            oid
            messageHeadline
            statusCheckRollup { state }
          }
        }
      }
      openIssues: issues(states: OPEN, first: 8, orderBy: {field: UPDATED_AT, direction: DESC}) {
        totalCount
        nodes { number title url updatedAt }
      }
      closedIssues: issues(states: CLOSED, first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
        totalCount
        nodes { number title url closedAt }
      }
      openPrs: pullRequests(states: OPEN, first: 8, orderBy: {field: UPDATED_AT, direction: DESC}) {
        totalCount
        nodes {
          number title url isDraft updatedAt
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
      }
      mergedPrs: pullRequests(states: MERGED, first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
        totalCount
        nodes { number title url mergedAt }
      }
    }
  }
  """

  @doc "Fetch and shape the overview for `\"owner/name\"`."
  def fetch(repo) do
    with [owner, name] <- String.split(repo, "/", parts: 2),
         {:ok, token} <- token(),
         client = GhEx.new(auth: {:token, token}),
         {:ok, %{"repository" => repository}, _meta} when is_map(repository) <-
           GhEx.GraphQL.query(client, @query, owner: owner, name: name) do
      {:ok, shape(repo, repository)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp shape(repo, repository) do
    %{
      repo: repo,
      open_issues: section(repository["openIssues"], &item(&1, "updatedAt")),
      closed_issues: section(repository["closedIssues"], &item(&1, "closedAt")),
      open_prs: section(repository["openPrs"], &pr_item/1),
      merged_prs: section(repository["mergedPrs"], &item(&1, "mergedAt")),
      default_branch: default_branch(repository["defaultBranchRef"]),
      fetched_at: DateTime.utc_now()
    }
  end

  # The branch build (#310). Rides the query that was already being made, so
  # watching main costs no extra API call. `nil` when the repository has no
  # default branch (empty repo) or the rollup has not reported yet -- absent
  # is not the same as red, and only red is a signal.
  defp default_branch(nil), do: nil

  defp default_branch(ref) do
    %{
      name: ref["name"],
      state: get_in(ref, ["target", "statusCheckRollup", "state"]),
      oid: get_in(ref, ["target", "oid"]),
      headline: get_in(ref, ["target", "messageHeadline"])
    }
  end

  defp section(%{"totalCount" => total, "nodes" => nodes}, item_fun),
    do: %{total: total, items: Enum.map(nodes, item_fun)}

  defp section(_missing, _item_fun), do: %{total: 0, items: []}

  defp item(node, at_key) do
    %{
      number: node["number"],
      title: node["title"],
      url: node["url"],
      at: parse_at(node[at_key])
    }
  end

  defp pr_item(node) do
    checks =
      get_in(node, ["commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "state"])

    node
    |> item("updatedAt")
    |> Map.merge(%{draft: node["isDraft"] == true, checks: checks})
  end

  defp parse_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parse_at(_missing), do: nil

  defp token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _unset -> cli_token()
    end
  end

  defp cli_token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        with {out, 0} <- System.cmd("gh", ["auth", "token"], stderr_to_stdout: true),
             token when token != "" <- String.trim(out) do
          :persistent_term.put({__MODULE__, :token}, token)
          {:ok, token}
        else
          _failure -> {:error, :no_github_token}
        end

      token ->
        {:ok, token}
    end
  end
end
