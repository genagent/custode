defmodule CustodeWeb.SuggestionsLiveTest do
  # The suggestions page (#284): shows ALL standing suggestions with full
  # evidence, and applies one through the shared context.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    feed = Path.join(System.tmp_dir!(), uid("sugg-lv-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    Custode.Repo.query!(
      "DELETE FROM feed_entries WHERE event IN ('advisor_suggestion','advisor_applied','advisor_dismissed')"
    )

    on_exit(fn -> File.rm(feed) end)
    %{conn: build_conn()}
  end

  defp suggest!(agent, field, proposed, evidence) do
    Custode.Feed.record(%{
      event: "advisor_suggestion",
      agent: agent,
      advisor: "advisor-cadence",
      field: field,
      current: "@daily",
      proposed: proposed,
      confidence: "medium",
      evidence: evidence
    })
  end

  test "lists all standing suggestions with their full evidence", %{conn: conn} do
    for n <- 1..5 do
      suggest!("routine-#{n}", "cron", "*/30 9-18 * * *", "full evidence sentence number #{n}")
    end

    {:ok, view, html} = live(conn, "/suggestions")
    assert has_element?(view, ~s|ul[aria-label="Standing suggestions"] > li:nth-child(5)|)
    refute has_element?(view, ~s|ul[aria-label="Standing suggestions"] > li:nth-child(6)|)

    # all five appear (the rail would cap at 3; this page does not)
    assert html =~ "5 standing suggestions"

    for n <- 1..5 do
      assert html =~ "routine-#{n}"
      assert html =~ "full evidence sentence number #{n}"
    end
  end

  test "applying a suggestion writes it and drops it from the list", %{conn: conn} do
    roster = Path.join(System.tmp_dir!(), uid("apply-roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", roster)
    previous = Application.get_env(:custode, :routines)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(roster)
      Application.put_env(:custode, :routines, previous)
    end)

    ws = tmp_workspace!()
    id = uid("wk")
    put_env!(:routines, [%{id: id, cron: "@daily", workspace: ws, prompt: "s"}])
    suggest!(id, "model", "haiku", "opus is overkill for this repo")

    {:ok, view, html} = live(conn, "/suggestions")
    assert html =~ id
    assert html =~ "1 standing suggestion from"

    view
    |> element("button[phx-value-agent='#{id}'][phx-value-field='model']", "Apply")
    |> render_click()

    assert Custode.Routine.get(id).model == "haiku"
    refute render(view) =~ "opus is overkill"
  end

  test "an empty board explains itself", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/suggestions")
    assert html =~ "no standing suggestions"
    assert html =~ "0 standing suggestions"
  end
end
