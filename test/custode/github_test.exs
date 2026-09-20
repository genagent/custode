defmodule Custode.GitHubTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ExUnit.CaptureLog

  alias Custode.GitHub.Cache
  alias Custode.Test.FakeGitHubFetcher

  doctest Custode.GitHub.Cache

  setup do
    Custode.PubSubBridge.subscribe()
    :ok
  end

  defp fake!(repo, result) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, result))
  end

  # A repo name no other test uses, whose rows leave the (global) cache table
  # with the test.
  defp repo!(prefix) do
    repo = "acme/" <> uid(prefix)
    on_exit(fn -> Cache.forget(repo) end)
    repo
  end

  # The read's clock, this far past the real one. A window is measured from
  # when the failure LANDED, which is never later than the moment this is
  # called, so `later(61_000)` is always past a 60 second window.
  defp later(ms), do: System.monotonic_time(:millisecond) + ms

  # One failed fetch, start to finish: the read that kicks it, the fetch
  # itself, and the cache recording the result.
  defp fail!(repo, opts \\ []) do
    Custode.GitHub.overview(repo, opts)
    assert_receive {:github_fetch, ^repo}, 1_000
    settled!(repo)
  end

  # A repeat failure broadcasts nothing, so "the result has been recorded" is
  # read off the cache itself: a repo leaves `in_flight` in the same callback
  # that writes its row.
  defp settled!(repo) do
    eventually(fn ->
      in_flight = :sys.get_state(Cache).in_flight
      refute MapSet.member?(in_flight, repo)
    end)
  end

  defp flush_fetches(repo) do
    receive do
      {:github_fetch, ^repo} -> flush_fetches(repo)
    after
      0 -> :ok
    end
  end

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

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

  describe "a failed fetch (#485)" do
    # every test here makes the cache warn, on purpose
    @describetag :capture_log

    setup do
      put_env!(:fake_github_fetch_observer, self())
      :ok
    end

    test "answers {:error, reason} and is not refetched inside the first window" do
      repo = repo!("fail")
      fake!(repo, {:error, :boom})

      assert Custode.GitHub.overview(repo) == :loading
      assert_receive {:github_fetch, ^repo}, 1_000
      # the failure lands as a broadcast too, so a page stops showing loading
      assert_receive {:repo_overview, ^repo}, 1_000

      assert Custode.GitHub.overview(repo) == {:error, ":boom"}
      assert Custode.GitHub.overview(repo, now: later(50_000)) == {:error, ":boom"}
      refute_receive {:github_fetch, ^repo}, 200

      assert Custode.GitHub.overview(repo, now: later(61_000)) == {:error, ":boom"}
      assert_receive {:github_fetch, ^repo}, 1_000
    end

    test "the window after a consecutive failure is longer than the first" do
      repo = repo!("again")
      fake!(repo, {:error, :boom})

      fail!(repo)
      fail!(repo, now: later(61_000))

      # 61 seconds cleared the first window and does not clear the second
      Custode.GitHub.overview(repo, now: later(61_000))
      Custode.GitHub.overview(repo, now: later(290_000))
      refute_receive {:github_fetch, ^repo}, 200

      Custode.GitHub.overview(repo, now: later(301_000))
      assert_receive {:github_fetch, ^repo}, 1_000
    end

    test "the two windows are :github_retry_first_ms and :github_retry_repeat_ms" do
      repo = repo!("windows")
      fake!(repo, {:error, :boom})
      put_env!(:github_retry_first_ms, 5_000)
      put_env!(:github_retry_repeat_ms, 9_000)

      fail!(repo)
      Custode.GitHub.overview(repo, now: later(4_000))
      refute_receive {:github_fetch, ^repo}, 200

      fail!(repo, now: later(6_000))
      Custode.GitHub.overview(repo, now: later(6_000))
      refute_receive {:github_fetch, ^repo}, 200

      Custode.GitHub.overview(repo, now: later(10_000))
      assert_receive {:github_fetch, ^repo}, 1_000
    end

    test "a success clears it, and the next failure starts from the first window again" do
      repo = repo!("recover")
      put_env!(:github_ttl_ms, 0)
      fake!(repo, {:error, :boom})

      fail!(repo)
      assert_receive {:repo_overview, ^repo}, 1_000
      fail!(repo, now: later(61_000))

      fake!(repo, {:ok, FakeGitHubFetcher.overview(repo)})
      assert {:error, ":boom"} = Custode.GitHub.overview(repo, now: later(301_000))
      assert_receive {:github_fetch, ^repo}, 1_000
      assert_receive {:repo_overview, ^repo}, 1_000
      assert {:ok, %{repo: ^repo}} = Custode.GitHub.overview(repo)
      settled!(repo)
      flush_fetches(repo)

      # ttl 0: that read kicked a refresh. Fail it, and the window that opens
      # is the 60 second one, where a third consecutive failure would be 300.
      fake!(repo, {:error, :boom})
      fail!(repo)

      Custode.GitHub.overview(repo, now: later(61_000))
      assert_receive {:github_fetch, ^repo}, 1_000
    end

    test "a stale overview is still served while its refresh fails, and is not refetched" do
      repo = repo!("stale-fail")
      put_env!(:github_ttl_ms, 0)
      fake!(repo, {:ok, FakeGitHubFetcher.overview(repo, %{open_prs: %{total: 4, items: []}})})

      :loading = Custode.GitHub.overview(repo)
      assert_receive {:github_fetch, ^repo}, 1_000
      assert_receive {:repo_overview, ^repo}, 1_000

      fake!(repo, {:error, :boom})
      fail!(repo)

      # stale beats blank: the failure stops the refetching, not the serving
      assert {:ok, %{open_prs: %{total: 4}}} = Custode.GitHub.overview(repo)
      assert {:ok, %{open_prs: %{total: 4}}} = Custode.GitHub.overview(repo, now: later(50_000))
      refute_receive {:github_fetch, ^repo}, 200
    end

    test "logs one warning per transition and one info on recovery, nothing on a repeat" do
      repo = repo!("log")
      put_env!(:github_ttl_ms, 0)
      fake!(repo, {:error, :boom})

      log =
        capture_log(fn ->
          fail!(repo)
          fail!(repo, now: later(61_000))
          fail!(repo, now: later(400_000))

          fake!(repo, {:ok, FakeGitHubFetcher.overview(repo)})
          Custode.GitHub.overview(repo, now: later(800_000))
          assert_receive {:github_fetch, ^repo}, 1_000
          settled!(repo)

          # failing again after a recovery is a second transition
          fake!(repo, {:error, :boom})
          fail!(repo)
        end)

      assert occurrences(log, "github overview fetch failing for #{repo}") == 2
      assert occurrences(log, "github overview fetch recovered for #{repo}") == 1
      # five fetches, three lines: the two repeat failures said nothing
      assert occurrences(log, repo) == 3
    end

    test "the warning is one line with the repo and a short reason, never the error struct" do
      repo = repo!("saml")

      error = %GhEx.Error{
        status: 403,
        message: "Resource protected by organization SAML enforcement",
        body: %{"message" => "Resource protected by organization SAML enforcement"},
        documentation_url:
          "https://docs.github.com/articles/authenticating-to-a-github-organization",
        headers: %{
          "x-github-sso" => [
            "required; url=https://github.com/orgs/acme/sso?authorization_request=SECRET"
          ]
        }
      }

      fake!(repo, {:error, error})
      log = capture_log(fn -> fail!(repo) end)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ repo))
      assert line =~ "[warning]"
      assert line =~ "HTTP 403: Resource protected by organization SAML enforcement"

      refute log =~ "headers"
      refute log =~ "authorization"
      refute log =~ "SECRET"
      refute log =~ "GhEx.Error"

      # the page gets the same line the log did
      assert Custode.GitHub.overview(repo) ==
               {:error, "HTTP 403: Resource protected by organization SAML enforcement"}
    end
  end

  describe "short_reason/1 (#485)" do
    test "an error with neither a status nor a message is never inspected" do
      error = %GhEx.Error{headers: %{"x-github-sso" => ["url=https://x?authorization_request=1"]}}
      assert Cache.short_reason(error) == "GitHub API error"
    end

    test "a response the fetcher could not read is named, not dumped" do
      assert Cache.short_reason({:unexpected, {:ok, %{"repository" => nil}, %{}}}) ==
               "unexpected response"
    end

    test "a transport exception is its message on one line" do
      assert Cache.short_reason(%RuntimeError{message: "connection closed\nmid-response"}) ==
               "connection closed mid-response"
    end

    test "a long reason is clipped to 120 characters" do
      assert String.length(Cache.short_reason(String.duplicate("x", 500))) == 120

      assert String.length(Cache.short_reason(%GhEx.Error{message: String.duplicate("y", 500)})) ==
               120
    end
  end

  test "the fetcher seam is honored" do
    assert Custode.GitHub.fetcher() == Custode.Test.FakeGitHubFetcher
  end
end
