defmodule CustodeWeb.FeedLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("fl-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    %{conn: build_conn()}
  end

  test "renders the backlog and streams new entries live", %{conn: conn} do
    Custode.Feed.record(%{event: "turn", agent: "a", summary: "already happened"})

    {:ok, view, html} = live(conn, "/feed")
    assert html =~ "already happened"

    Custode.Feed.record(%{event: "turn", agent: "a", summary: "just now"})
    assert render(view) =~ "just now"
  end

  test "the agent filter narrows the stream and gates live inserts", %{conn: conn} do
    Custode.Feed.record(%{event: "turn", agent: "alpha", summary: "alpha backlog"})
    Custode.Feed.record(%{event: "turn", agent: "beta", summary: "beta backlog"})

    {:ok, view, html} = live(conn, "/feed?agent=alpha")
    assert html =~ "alpha backlog"
    refute html =~ "beta backlog"

    # a live entry for the filtered-out agent stays out of the stream
    Custode.Feed.record(%{event: "turn", agent: "beta", summary: "beta live"})
    refute render(view) =~ "beta live"

    # a live entry for the filtered agent still lands
    Custode.Feed.record(%{event: "turn", agent: "alpha", summary: "alpha live"})
    assert render(view) =~ "alpha live"

    # clearing the filter shows every agent again
    html = render_patch(view, "/feed")
    assert html =~ "alpha backlog"
    assert html =~ "beta backlog"
    assert html =~ "beta live"
  end

  test "the category filter narrows by event kind and gates live inserts (#211)", %{conn: conn} do
    Custode.Feed.record(%{event: "sensor", agent: "s", summary: "ci: nothing new"})
    Custode.Feed.record(%{event: "needs_approval", agent: "w", action: "prune the notes"})
    Custode.Feed.record(%{event: "turn", agent: "w", summary: "swept the yard"})

    {:ok, view, html} = live(conn, "/feed?kind=attention")
    assert html =~ "prune the notes"
    refute html =~ "ci: nothing new"
    refute html =~ "swept the yard"

    # a live sensor entry stays out of the attention view
    Custode.Feed.record(%{event: "sensor", agent: "s", summary: "ci: still nothing"})
    refute render(view) =~ "ci: still nothing"

    # a live attention entry lands
    Custode.Feed.record(%{event: "needs_input", agent: "w", question: "which env?"})
    assert render(view) =~ "which env?"

    # the two axes compose: kind + agent
    html = render_patch(view, "/feed?kind=turns&agent=w")
    assert html =~ "swept the yard"
    refute html =~ "prune the notes"
  end
end
