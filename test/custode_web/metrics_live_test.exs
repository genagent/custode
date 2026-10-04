defmodule CustodeWeb.MetricsLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Gates.Gate
  alias Custode.Gates.Grant
  alias Custode.Repo
  alias Custode.SpendLedger
  alias Custode.SpendLedger.Entry
  alias Custode.Workflow.Run

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("metrics-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    %{conn: build_conn()}
  end

  test "daily charts use recorded workflow ownership and separate metric rankings", %{conn: conn} do
    Repo.delete_all(Entry)
    workflow = uid("review-project")
    custom_run = uid("arbitrary-run")
    other_run = uid("another-run")
    Run.start(custom_run, workflow, "owner/repo", "review")
    Run.start(other_run, workflow, "owner/repo", "review")

    for run <- [custom_run, other_run] do
      SpendLedger.record(Run.spend_agent_id(run), 5.0, "turn", usage: %{input: 50})
    end

    agents = for n <- 1..6, do: {n, uid("project-#{n}")}

    for {n, agent} <- agents do
      SpendLedger.record(agent, n * 1.0, "turn", usage: %{input: (7 - n) * 100})
    end

    [{_, token_leader} | _] = agents
    {:ok, view, _html} = live(conn, "/metrics")

    assert has_element?(view, "#daily-spend-legend", "Workflow: #{workflow}")
    refute has_element?(view, "#daily-spend", custom_run)
    refute has_element?(view, "#daily-spend", other_run)
    refute has_element?(view, "#daily-spend-legend", "Agent: #{token_leader}")
    assert has_element?(view, "#daily-tokens-legend", "Agent: #{token_leader}")
    refute has_element?(view, "#daily-tokens-legend", "Workflow: #{workflow}")

    for chart <- ["daily-spend", "daily-tokens"] do
      assert has_element?(view, "##{chart}-legend", "Other")
      assert has_element?(view, "##{chart} [data-chart-zero]")
      assert has_element?(view, "##{chart} [data-chart-today=true]")
      assert has_element?(view, "##{chart}-values-disclosure summary", "Exact daily values")
    end

    assert has_element?(view, "#daily-spend-values", "31.0 USD")
    assert has_element?(view, "#daily-tokens-values", "2200 tokens")
    assert has_element?(view, "#daily-turns-values", "8 turns")
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

  # what the fleet writes outside an approved action (#451)
  test "writes outside a grant are counted by agent, verb and verdict", %{conn: conn} do
    Repo.query!("DELETE FROM feed_entries WHERE event = 'grant_outside'")

    {:ok, _view, html} = live(conn, "/metrics")
    assert html =~ "none observed"
    assert html =~ "mode: observe"

    sweeper = uid("sweeper")
    for _n <- 1..2, do: Grant.check(sweeper, :comment)

    {:ok, view, _html} = live(conn, "/metrics")
    table = view |> element("section", "writes outside a grant") |> render()

    assert table =~ ~r/#{sweeper}.*comment.*no_grant.*>2</s
  end
end
