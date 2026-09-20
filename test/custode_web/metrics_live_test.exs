defmodule CustodeWeb.MetricsLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Gates.Gate
  alias Custode.Repo

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("metrics-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    %{conn: build_conn()}
  end

  defp gate!(agent_id, outcome, class \\ nil) do
    Repo.insert!(%Gate{
      agent_id: agent_id,
      kind: "approval",
      class: class,
      action_id: uid("act"),
      detail: "x",
      status: "resolved",
      outcome: outcome
    })
  end

  # whether a gate is a decision or a formality (#448)
  test "the approval rate table shows each agent's decided gates", %{conn: conn} do
    rubber_stamp = uid("always")
    contested = uid("sometimes")

    for _n <- 1..3, do: gate!(rubber_stamp, "approved")
    gate!(contested, "approved")
    gate!(contested, "rejected")

    {:ok, _view, html} = live(conn, "/metrics")

    assert html =~ "approval rate"
    assert html =~ rubber_stamp
    assert html =~ "100%"
    assert html =~ contested
    assert html =~ "50%"
  end

  # the same question by class of action (#451)
  test "the by-class table counts only gates that declared a class", %{conn: conn} do
    Repo.delete_all(Gate)

    {:ok, _view, html} = live(conn, "/metrics")
    assert html =~ "no decided gate has declared a class yet"

    agent = uid("classy")
    for _n <- 1..3, do: gate!(agent, "approved", "ready_pr")
    gate!(agent, "rejected", "merge")
    gate!(agent, "approved")

    {:ok, view, _html} = live(conn, "/metrics")
    table = view |> element("section", "approval rate by class") |> render()

    assert table =~ ~r/ready_pr.*>3<.*>0<.*100%/s
    assert table =~ ~r/merge.*>0<.*>1<.*0%/s
    refute table =~ "no decided gate"
  end
end
