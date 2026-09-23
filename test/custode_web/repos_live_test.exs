defmodule CustodeWeb.ReposLiveTest do
  # The repositories page (#193): one tile per distinct repo, agents share it.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.GitHub.Cache
  alias Custode.Test.FakeGitHubFetcher
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run

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
    refute html =~ "/console/#{no_repo_id}"

    # both agents ride the same tile as links, each showing its role (#255)
    assert html =~ "/console/#{worker_id}"
    assert html =~ "/console/#{steward_id}"
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

  # #485: a repo GitHub refuses never gets an overview, and the tile used to
  # show loading dots for as long as the page was open.
  @tag :capture_log
  test "a repo GitHub refuses says so in its tile in place of loading forever", %{conn: conn} do
    repo = "acme/" <> uid("refused")
    on_exit(fn -> Cache.forget(repo) end)

    refusal = %GhEx.Error{
      status: 403,
      message: "Resource protected by organization SAML enforcement"
    }

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, refusal}))

    put_env!(:routines, [
      %{id: uid("worker"), profile: :backlog_worker, workspace: tmp_workspace!(), repo: repo}
    ])

    {:ok, view, _html} = live(conn, "/repos")

    # the first render races the async fetch; the failure broadcasts, and the
    # page re-pulls on it
    html =
      eventually(fn ->
        html = render(view)
        assert html =~ "GitHub refused this repository: HTTP 403: Resource protected"
        html
      end)

    refute html =~ "loading-dots"
  end

  test "an empty roster explains itself", %{conn: conn} do
    previous = Application.get_env(:custode, :routines)
    put_env!(:routines, [])
    on_exit(fn -> Application.put_env(:custode, :routines, previous) end)

    {:ok, _view, html} = live(conn, "/repos")
    assert html =~ "no repositories in the roster"
  end

  # design/005 slice 3 (#273): the button is repo-scoped, so it lives on the
  # page that is repo-scoped -- and it opens the slice-2 gate, never a run.
  test "each repo carries a workflow button, and the click opens a gate", %{conn: conn} do
    repo = "acme/" <> uid("launch")
    workflow = workflow_fixture!(uid("toy"))

    on_exit(fn ->
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
    end)

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

    put_env!(
      :fake_repo_overviews,
      Map.put(overviews, repo, {:ok, FakeGitHubFetcher.overview(repo)})
    )

    put_env!(:routines, [
      %{id: uid("worker"), profile: :backlog_worker, workspace: tmp_workspace!(), repo: repo}
    ])

    {:ok, view, html} = live(conn, "/repos")
    assert html =~ "run a workflow"
    assert html =~ workflow.name
    # the floor comes from the definition, so the menu needs no ledger read
    assert html =~ "3+ nodes"

    html = view |> element("button[phx-value-workflow='#{workflow.name}']") |> render_click()

    # the visible answer to the click: the entry becomes the standing gate
    assert html =~ "gate already standing"
    assert [entry] = Enum.filter(Launch.pending(), &(&1["repo"] == repo))
    assert entry["why"] =~ "repositories page"
    assert Enum.filter(Run.list(), &(&1.workflow == workflow.name)) == []
  end

  test "the shared chrome carries the repos nav on every page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/feed")
    assert html =~ ~s(href="/repos")
  end
end
