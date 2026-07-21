defmodule Custode.GitHubTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Test.FakeGitHubFetcher

  setup do
    Custode.PubSubBridge.subscribe()
    :ok
  end

  defp fake!(repo, result) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, result))
  end

  test "a cold miss returns :loading, then the fetch lands and broadcasts" do
    repo = "acme/" <> uid("cold")
    fake!(repo, {:ok, FakeGitHubFetcher.overview(repo, %{open_issues: %{total: 3, items: []}})})

    assert Custode.GitHub.overview(repo) == :loading
    assert_receive {:repo_overview, ^repo}, 1_000
    assert {:ok, %{open_issues: %{total: 3}}} = Custode.GitHub.overview(repo)
  end

  test "a stale hit serves the old overview while the refresh runs" do
    repo = "acme/" <> uid("stale")
    fake!(repo, {:ok, FakeGitHubFetcher.overview(repo, %{open_prs: %{total: 1, items: []}})})
    put_env!(:github_ttl_ms, 0)

    :loading = Custode.GitHub.overview(repo)
    assert_receive {:repo_overview, ^repo}, 1_000

    # ttl 0: the entry is already expired, but the read still answers
    fake!(repo, {:ok, FakeGitHubFetcher.overview(repo, %{open_prs: %{total: 9, items: []}})})
    assert {:ok, %{open_prs: %{total: 1}}} = Custode.GitHub.overview(repo)

    # ...and the refresh it kicked replaces the entry
    assert_receive {:repo_overview, ^repo}, 1_000
    assert {:ok, %{open_prs: %{total: 9}}} = Custode.GitHub.overview(repo)
  end

  test "a failed fetch keeps :loading, logs, and the next read retries" do
    repo = "acme/" <> uid("err")
    fake!(repo, {:error, :boom})

    :loading = Custode.GitHub.overview(repo)
    refute_receive {:repo_overview, ^repo}, 200
    assert Custode.GitHub.overview(repo) == :loading

    # recovery: once GitHub answers, the same read path fills in. A prior
    # error fetch may still be in flight and dedup a single re-cast, so
    # keep knocking until the success fetch lands and broadcasts.
    fake!(repo, {:ok, FakeGitHubFetcher.overview(repo)})

    landed? =
      Enum.any?(1..50, fn _attempt ->
        Custode.GitHub.overview(repo)

        receive do
          {:repo_overview, ^repo} -> true
        after
          50 -> false
        end
      end)

    assert landed?, "success fetch never landed"
    assert {:ok, %{repo: ^repo}} = Custode.GitHub.overview(repo)
  end

  test "the fetcher seam is honored" do
    assert Custode.GitHub.fetcher() == Custode.Test.FakeGitHubFetcher
  end
end
