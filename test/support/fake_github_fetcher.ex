defmodule Custode.Test.FakeGitHubFetcher do
  @moduledoc """
  Test stand-in for `Custode.GitHub.Fetcher`: returns canned overviews set
  via `Application.put_env(:custode, :fake_repo_overviews, %{"owner/name" =>
  {:ok, overview} | {:error, reason}})`. Unlisted repos error, so a test
  never hits the network by accident.
  """

  @behaviour Custode.GitHub.FetcherBehaviour

  @impl true
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
        # green by default (#310): a fixture that is red unless told otherwise
        # would put every unrelated test's repo in the needs-you group
        default_branch: %{name: "main", state: "SUCCESS", oid: "abc1234", headline: "a commit"},
        # freshly released by default (#336): a fixture that reads as overdue
        # would make every unrelated test's repo look due for a release
        release: %{
          tag: "v1.0.0",
          published_at: DateTime.utc_now(),
          merged_since: 0,
          window_full?: false
        },
        fetched_at: DateTime.utc_now()
      },
      extra
    )
  end
end
