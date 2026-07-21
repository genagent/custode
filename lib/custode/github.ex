defmodule Custode.GitHub do
  @moduledoc """
  Read-side GitHub state for repo-tied routines: one GraphQL query per repo
  returns open + recently closed issues and open (with check status) +
  recently merged PRs, shaped for the dashboard's repository panels.

  `overview/1` never blocks on the network: it answers from the
  `Custode.GitHub.Cache` (serving stale data while a refresh is in flight)
  and returns `:loading` on a cold miss. When a refresh lands, the cache
  broadcasts `{:repo_overview, repo}` on the agents PubSub topic, so
  LiveViews re-pull instead of polling.

  The fetch itself lives behind the `:github_fetcher` config seam
  (`Custode.GitHub.Fetcher` for real, a fake in tests) -- the same pattern
  as the sensors' gh runner.
  """

  @doc """
  The cached overview for `"owner/name"`: `{:ok, overview}` (possibly stale,
  with a refresh in flight), or `:loading` before the first fetch lands.
  """
  def overview(repo) when is_binary(repo), do: Custode.GitHub.Cache.get(repo)

  @doc "The configured fetcher module (the test seam)."
  def fetcher, do: Application.get_env(:custode, :github_fetcher, Custode.GitHub.Fetcher)
end
