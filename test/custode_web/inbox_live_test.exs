defmodule CustodeWeb.InboxLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("inbox-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    # This module renders the WHOLE inbox, so the whole inbox has to be its
    # own. Every source it draws from persists in the shared db between tests:
    # asks, gates, and the feed rows Suggestions.standing/0 reads. Leaving any
    # of them makes an "empty inbox" assertion depend on test order. Safe
    # because these tests are async: false and never interleave.
    Custode.Repo.query!("DELETE FROM asks")
    Custode.Repo.query!("DELETE FROM gates")
    Custode.Repo.query!("DELETE FROM disowned_prs")
    Custode.Repo.query!("DELETE FROM feed_entries WHERE event = 'advisor_suggestion'")
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine, workspace: workspace}
  end

  test "an empty inbox says so rather than showing a bare page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ "Nothing needs you"
    # and it points at where the fleet's state actually is
    assert html =~ "fleet page"
  end

  test "a question renders with its text and a reply affordance",
       %{conn: conn, routine: routine} do
    {:ok, _ask} = Asks.ask(routine.id, "is the uncommitted diff yours?")

    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ routine.id
    assert html =~ "question"
    assert html =~ "asked you a question"
    assert html =~ "is the uncommitted diff yours?"
    assert html =~ "Answer"
  end

  test "answering from the inbox closes the ask and tells the agent",
       %{conn: conn, routine: routine, workspace: workspace} do
    {:ok, ask} = Asks.ask(routine.id, "which env?")

    {:ok, view, _html} = live(conn, "/inbox")

    # a question is a conversation, so the affordance is a reply box
    html = view |> element("button", "Answer") |> render_click()
    assert html =~ "reply to #{routine.id}"

    view
    |> form("form[phx-submit=reply_send]", %{"ask" => ask.id, "text" => "staging"})
    |> render_submit()

    assert Asks.get(ask.id).status == "answered"
    assert File.exists?(Path.join([Path.expand(workspace), "inbox", "answer-#{ask.id}.md"]))

    # and it leaves the inbox
    refute render(view) =~ "which env?"
  end

  test "the hard bottom names what it left out", %{conn: conn, routine: routine} do
    {:ok, _ask} = Asks.ask(routine.id, "anything")

    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ "That&#39;s everything." or html =~ "That's everything."
    # the omission is stated, not silent -- that is what makes it trustworthy
    assert html =~ "Sweeps, sensor pings and journal entries"
    assert html =~ "on their agents"
  end

  test "/feed keeps its route after leaving the top nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/inbox")
    refute html =~ ~s(href="/feed")

    assert {:ok, _view, _html} = live(conn, "/feed")
  end
end
