defmodule Custode.GitHub do
  @moduledoc """
  Read-side GitHub state for repo-tied routines: one GraphQL query per repo
  returns open + recently closed issues and open (with check status) +
  recently merged PRs, shaped for the dashboard's repository panels.

  `overview/2` never blocks on the network: it answers from the
  `Custode.GitHub.Cache` (serving stale data while a refresh is in flight)
  and returns `:loading` on a cold miss. When a refresh lands, the cache
  broadcasts `{:repo_overview, repo}` on the agents PubSub topic, so
  LiveViews re-pull instead of polling.

  A repo GitHub will not serve answers `{:error, reason}` (#485), and the
  cache retries it on a backoff rather than on every read. Every caller has
  to treat that as "no data": a page says so, and `Custode.Attention.Fleet`
  makes no claim about a branch or a check it could not read.

  The fetch itself lives behind the `:github_fetcher` config seam
  (`Custode.GitHub.Fetcher` for real, a fake in tests) -- the same pattern
  as the sensors' gh runner.
  """

  alias Custode.GitHub.Cache

  @doc """
  The cached overview for `"owner/name"`: `{:ok, overview}` (possibly stale,
  with a refresh in flight), `:loading` before the first fetch lands, or
  `{:error, reason}` when the fetch failed and there is nothing cached to
  serve. `reason` is one short line fit for a page.

  `opts` are `Custode.GitHub.Cache.get/2`'s: `:now`, the read's clock.
  """
  @spec overview(String.t(), keyword()) :: Cache.reading()
  def overview(repo, opts \\ []) when is_binary(repo), do: Cache.get(repo, opts)

  @doc "The configured fetcher module (the test seam)."
  def fetcher, do: Application.get_env(:custode, :github_fetcher, Custode.GitHub.Fetcher)
end

defmodule Custode.GitHub.FetcherBehaviour do
  @moduledoc "The `:github_fetcher` contract (#92): one repo overview fetch."

  @callback fetch(repo :: String.t()) :: {:ok, map()} | {:error, term()}
end
