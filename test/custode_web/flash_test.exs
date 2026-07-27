defmodule CustodeWeb.FlashTest do
  @moduledoc """
  The flash is rendered (#337).

  Twenty `put_flash/3` calls across five LiveViews had no renderer anywhere
  in the app, so a refused apply looked exactly like a successful one:
  nothing on screen. These tests assert the message reaches the PAGE, not
  just the socket assigns -- which is the whole distinction the bug turned
  on, and the reason the container lives in the live layout rather than the
  root one.
  """
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks

  @endpoint CustodeWeb.Endpoint

  setup do
    Custode.Repo.query!("DELETE FROM asks")
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine}
  end

  test "an info flash from handle_event shows up on the page",
       %{conn: conn, routine: routine} do
    {:ok, ask} = Asks.ask(routine.id, "which env?")

    {:ok, view, _html} = live(conn, "/inbox")
    view |> element("button", "Answer") |> render_click()

    html =
      view
      |> form("form[phx-submit=reply_send]", %{"ask" => ask.id, "text" => "staging"})
      |> render_submit()

    assert html =~ "answered; #{routine.id} reads it on its next sweep"
    assert html =~ "alert-info"
  end

  test "an error flash shows up, and reads as an error",
       %{conn: conn, routine: routine} do
    {:ok, ask} = Asks.ask(routine.id, "which env?")

    {:ok, view, _html} = live(conn, "/inbox")
    view |> element("button", "Answer") |> render_click()

    # an empty answer is refused, and the refusal is the thing that used to
    # be invisible
    html =
      view
      |> form("form[phx-submit=reply_send]", %{"ask" => ask.id, "text" => ""})
      |> render_submit()

    assert html =~ "an answer to #{ask.id} needs text"
    assert html =~ "alert-error"
  end

  test "clicking a flash dismisses it", %{conn: conn, routine: routine} do
    {:ok, ask} = Asks.ask(routine.id, "which env?")

    {:ok, view, _html} = live(conn, "/inbox")
    view |> element("button", "Answer") |> render_click()

    view
    |> form("form[phx-submit=reply_send]", %{"ask" => ask.id, "text" => ""})
    |> render_submit()

    html = view |> element("#flash-error") |> render_click()

    refute html =~ "an answer to #{ask.id} needs text"
  end
end
