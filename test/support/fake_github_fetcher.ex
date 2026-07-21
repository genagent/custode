defmodule Custode.Test.FakeGitHubFetcher do
  @moduledoc """
  Test stand-in for `Custode.GitHub.Fetcher`: returns canned overviews set
  via `Application.put_env(:custode, :fake_repo_overviews, %{"owner/name" =>
  {:ok, overview} | {:error, reason}})`. Unlisted repos error, so a test
  never hits the network by accident.
  """

  def fetch(repo) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    Map.get(overviews, repo, {:error, :not_faked})
  end

  @doc "A minimal well-formed overview for `repo`, deep-merged with `extra`."
  def overview(repo, extra \\ %{}) do
    Map.merge(
      %{
        repo: repo,
        open_issues: %{total: 0, items: []},
        closed_issues: %{total: 0, items: []},
        open_prs: %{total: 0, items: []},
        merged_prs: %{total: 0, items: []},
        fetched_at: DateTime.utc_now()
      },
      extra
    )
  end
end
