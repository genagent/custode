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

  defp gate!(agent_id, outcome) do
    Repo.insert!(%Gate{
      agent_id: agent_id,
      kind: "approval",
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
end
