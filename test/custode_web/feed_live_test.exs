defmodule CustodeWeb.FeedLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
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
end
