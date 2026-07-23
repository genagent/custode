defmodule CustodeWeb.ReposLiveTest do
  # The repositories page (#193): one tile per distinct repo, agents share it.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Test.FakeGitHubFetcher

  @endpoint CustodeWeb.Endpoint

  setup do
    %{conn: build_conn()}
  end

  test "repos dedupe across the roster; the tile links every agent working it", %{conn: conn} do
    repo = "acme/" <> uid("shared")

    overview =
      FakeGitHubFetcher.overview(repo, %{
        open_issues: %{
          total: 3,
          items: [%{number: 7, title: "coverage is slipping", url: "https://x", at: nil}]
        }
      })

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

    # one env write: routine_fixture! replaces the roster on every call
    worker_id = uid("worker")
    steward_id = uid("steward")
    no_repo_id = uid("solo")

    put_env!(:routines, [
      %{id: worker_id, profile: :backlog_worker, workspace: tmp_workspace!(), repo: repo},
      %{id: steward_id, profile: :steward, workspace: tmp_workspace!(), repo: repo},
      %{id: no_repo_id, cron: "@daily", workspace: tmp_workspace!(), prompt: "sweep"}
    ])

    Custode.PubSubBridge.subscribe()
    {:ok, view, html} = live(conn, "/repos")

    # one section for the shared repo, no tile for the repo-less routine
    assert html =~ repo
    refute html =~ "/agents/#{no_repo_id}"

    # both agents ride the same tile as links, each showing its role (#255)
    assert html =~ "/agents/#{worker_id}"
    assert html =~ "/agents/#{steward_id}"
    assert html =~ "backlog_worker"
    assert html =~ "steward"

    # the panel fills in live off the same cache/broadcast the agent page uses
    html =
      if html =~ "coverage is slipping" do
        html
      else
        assert_receive {:repo_overview, _repo}, 1_000
        render(view)
      end

    assert html =~ "3 open"
    assert html =~ "coverage is slipping"
  end

  test "an empty roster explains itself", %{conn: conn} do
    previous = Application.get_env(:custode, :routines)
    put_env!(:routines, [])
    on_exit(fn -> Application.put_env(:custode, :routines, previous) end)

    {:ok, _view, html} = live(conn, "/repos")
    assert html =~ "no repositories in the roster"
  end

  test "the shared chrome carries the repos nav on every page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/feed")
    assert html =~ ~s(href="/repos")
  end
end
