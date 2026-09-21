defmodule CustodeWeb.RootLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("root-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{id: uid("custode"), cron: "@daily", workspace: workspace, prompt: "tend", tags: [:meta]},
      %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    [caretaker, _worker] = Custode.Routine.all()
    %{conn: build_conn(), caretaker: caretaker}
  end

  # the caretaker proposing a change: run:stop first, then job_finished, the
  # order the engine's worker uses
  defp propose!(caretaker, action) do
    {:ok, _pid} = Agent.start_agent(caretaker.id, enqueue_fun: fn _a, _m -> {:ok, :queued} end)
    on_exit(fn -> Agent.stop_agent(caretaker.id) end)
    :processing = Agent.submit_prompt(caretaker.id, "x")

    result = structured_result(%{"directive" => "request_permission", "action" => action})

    :ok =
      Ingest.handle_event(
        [:oban_claude, :run, :stop],
        %{cost_usd: 0.0},
        %{result: result, job: %{meta: %{"agent_id" => caretaker.id}}},
        nil
      )

    :ok = Agent.job_finished(caretaker.id, {:ok, result})
    {:ok, _status} = Agent.await(caretaker.id, :awaiting_permission, 1_000)
    eventually(fn -> assert [_gate] = Gates.open_gates(caretaker.id) end)
  end

  test "the page is a sentence box, sentences to try, and what custode did", %{
    conn: conn,
    caretaker: caretaker
  } do
    Custode.Feed.record(%{event: "turn", agent: caretaker.id, summary: "fleet is quiet"})
    Custode.Feed.record(%{event: "roster_added", agent: caretaker.id, summary: "added mcp-repl"})
    Custode.Feed.record(%{event: "sensor", agent: caretaker.id, summary: "deadman: nothing new"})

    {:ok, view, html} = live(conn, "/custode")

    assert html =~ "speaks for you"
    assert has_element?(view, "form[phx-submit=tell] textarea[name=text]")
    # what it SAID and what it DID are different lists, and a ping is neither
    assert view |> element("#custode-said") |> render() =~ "fleet is quiet"
    did = view |> element("#custode-did") |> render()
    assert did =~ "added mcp-repl"
    refute did =~ "fleet is quiet"
    refute did =~ "deadman"
    # nothing pending, so no plan
    refute has_element?(view, "#custode-will")
  end

  test "a sentence to try fills the box and does not send", %{conn: conn} do
    {:ok, view, html} = live(conn, "/custode")
    assert html =~ "also try"

    html =
      view
      |> element(~s(button[phx-click=try]), "pause everything except")
      |> render_click()

    assert html =~ ~r/<textarea[^>]*>\s*pause everything except mdbook-lint until Monday/
    refute has_element?(view, "#root-notice")
  end

  test "a sentence reaches custode in any state, and the page says how", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/custode")

    html = view |> form("form[phx-submit=tell]", %{"text" => "what needs me?"}) |> render_submit()

    # the caretaker was offline: the sentence started its turn
    assert html =~ "custode was offline: started a turn with your sentence"
  end

  test "custode's pending proposal is the plan, and do it approves it", %{
    conn: conn,
    caretaker: caretaker
  } do
    propose!(caretaker, "add routine mcp-repl:\n\n    [[routines]]\n    id = \"mcp-repl\"")

    {:ok, view, _html} = live(conn, "/custode")

    plan = view |> element("#custode-will") |> render()
    assert plan =~ "add routine mcp-repl"
    assert plan =~ "do it"
    assert plan =~ "cancel"

    html = view |> element("button[phx-click=do_it]") |> render_click()
    assert html =~ "approved: custode is doing it"
    assert Gates.open_gates(caretaker.id) == []
    assert [%{outcome: "approved", decided_via: "liveview"} | _rest] = Gates.recent(1)
    refute has_element?(view, "#custode-will")
  end

  test "cancel is a rejection, and it needs a reason like every other", %{
    conn: conn,
    caretaker: caretaker
  } do
    propose!(caretaker, "raise custode's daily rail to $40")
    [gate] = Gates.open_gates(caretaker.id)

    {:ok, view, _html} = live(conn, "/custode")

    html =
      view
      |> form("#reject-form-#{gate.action_id}", %{
        "reason" => "not this week",
        "one_off" => "true"
      })
      |> render_submit()

    assert html =~ "cancelled"
    assert Gates.open_gates(caretaker.id) == []
    assert [%{outcome: "rejected", reason: "not this week"} | _rest] = Gates.recent(1)
  end

  test "with no caretaker the page says so and offers nothing to send", %{conn: conn} do
    put_env!(:routines, [])

    {:ok, view, html} = live(conn, "/custode")
    assert html =~ "there is no custode to talk to"
    refute has_element?(view, "form[phx-submit=tell]")
  end
end
