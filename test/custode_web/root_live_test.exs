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
    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(caretaker.id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(caretaker.id) end)
    :processing = Agent.submit_prompt(caretaker.id, "x")

    result = structured_result(%{"directive" => "request_permission", "action" => action})

    assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                   when enqueued_id == caretaker.id

    :ok =
      Ingest.handle_event(
        [:oban_claude, :run, :stop],
        %{cost_usd: 0.0},
        %{result: result, job: %{meta: turn_meta}},
        nil
      )

    :ok = finish_agent_turn(turn_meta, result)
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
    assert has_element?(view, "label[for=root-message-0]", "Message #{caretaker.id}")
    assert has_element?(view, "#root-message-0[name=text][aria-describedby=root-message-help-0]")

    assert has_element?(
             view,
             "#root-message-help-0",
             "Discuss an idea, ask about the fleet, or request work."
           )

    # what it SAID and what it DID are different lists, and a ping is neither
    assert view |> element("#custode-said") |> render() =~ "fleet is quiet"
    did = view |> element("#custode-did") |> render()
    assert did =~ "added mcp-repl"
    refute did =~ "fleet is quiet"
    refute did =~ "deadman"
    # nothing pending, so no plan
    refute has_element?(view, "#custode-will")
  end

  test "the primary application header is identical across operator surfaces", %{conn: conn} do
    {:ok, root, root_html} = live(conn, "/custode")
    {:ok, console, console_html} = live(conn, "/console")
    {:ok, repos, repos_html} = live(conn, "/repos")

    expected = [
      {"Console", "/console"},
      {"Ask", "/custode"},
      {"Inbox", "/inbox"},
      {"Repos", "/repos"},
      {"Suggestions", "/suggestions"},
      {"Workflows", "/workflows"},
      {"Metrics", "/metrics"}
    ]

    assert primary_nav(root_html) == expected
    assert primary_nav(console_html) == expected
    assert primary_nav(repos_html) == expected
    assert has_element?(root, "#application-header a[aria-current=page]", "Ask")
    assert has_element?(console, "#application-header a[aria-current=page]", "Console")
    assert has_element?(repos, "#application-header a[aria-current=page]", "Repos")
    assert has_element?(root, "#custode-root.max-w-4xl")
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

  defp primary_nav(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#application-header nav[aria-label=primary] a")
    |> Enum.map(fn link ->
      {link |> LazyHTML.text() |> String.trim(),
       link |> LazyHTML.attribute("href") |> List.first()}
    end)
  end
end
