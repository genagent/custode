defmodule CustodeWeb.ManagerConversationLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias Custode.{OperatorMessages, Repo}
  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    clear_attention!()
    path = Path.join(System.tmp_dir!(), uid("root-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{id: uid("custode"), cron: "@daily", workspace: workspace, prompt: "tend", tags: [:meta]},
      %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    [caretaker, worker] = Custode.Routine.all()
    %{conn: build_conn(), caretaker: caretaker, worker: worker}
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

  test "Ask uses the shared composer beside caretaker reports and activity", %{
    conn: conn,
    caretaker: caretaker
  } do
    Custode.Feed.record(%{event: "turn", agent: caretaker.id, summary: "fleet is quiet"})
    Custode.Feed.record(%{event: "roster_added", agent: caretaker.id, summary: "added mcp-repl"})
    Custode.Feed.record(%{event: "sensor", agent: caretaker.id, summary: "deadman: nothing new"})

    {:ok, view, html} = live(conn, "/custode")

    assert html =~ "Ask custode"
    assert has_element?(view, "label[for=message-input-0]", "Message #{caretaker.id}")
    assert has_element?(view, "#message-input-0[name=text][aria-describedby=message-help-0]")

    assert has_element?(
             view,
             "#message-help-0",
             "Sending starts a turn with your message."
           )

    assert has_element?(view, ~s(form[phx-hook=SubjectDraft][data-subject="#{caretaker.id}"]))
    assert has_element?(view, "#message-0 input[type=file]")
    assert has_element?(view, ~s(header a[href="/console/#{caretaker.id}"]), "control room")

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
    assert has_element?(root, "#conversation-scroll[phx-hook=ConversationScroll]")
  end

  test "a sentence to try restores the browser draft and does not send", %{
    conn: conn,
    caretaker: caretaker
  } do
    {:ok, view, html} = live(conn, "/custode")
    assert html =~ "also try"

    view |> element(~s(button[phx-click=try]), "pause everything except") |> render_click()

    caretaker_id = caretaker.id

    assert_push_event(view, "draft:restore", %{
      subject: ^caretaker_id,
      text: "pause everything except mdbook-lint until Monday"
    })

    assert {:ok, %{exchanges: []}} = OperatorMessages.conversation(caretaker.id)
    refute has_element?(view, "#conversation-notice")
  end

  test "a sentence reaches custode in any state, and the page says how", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/custode")

    html =
      view |> form("form[phx-submit=message]", %{"text" => "what needs me?"}) |> render_submit()

    # the caretaker was offline: the sentence started its turn
    assert html =~ "started a turn with your message"
  end

  test "custode's pending proposal is the plan, and do it approves it", %{
    conn: conn,
    caretaker: caretaker
  } do
    propose!(caretaker, "add routine mcp-repl:\n\n    [[routines]]\n    id = \"mcp-repl\"")

    {:ok, view, _html} = live(conn, "/custode")
    assert {:ok, %{exchanges: []}} = OperatorMessages.conversation(caretaker.id)

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

  test "cancel preserves the stated rejection reason", %{
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

  test "blank cancellation remains a rejection without inventing a standing reason", %{
    conn: conn,
    caretaker: caretaker
  } do
    propose!(caretaker, "review project priorities")
    [gate] = Gates.open_gates(caretaker.id)
    {:ok, view, _html} = live(conn, "/custode")

    assert render_submit(view, "reject", %{
             "agent" => caretaker.id,
             "action" => gate.action_id,
             "reason" => ""
           }) =~ "cancelled"

    assert Gates.open_gates(caretaker.id) == []
    assert [%{outcome: "rejected", reason: nil} | _rest] = Gates.recent(1)
  end

  test "with no caretaker the page says so and offers nothing to send", %{conn: conn} do
    put_env!(:routines, [])

    {:ok, view, html} = live(conn, "/custode")
    assert html =~ "There is no custode to talk to"
    assert has_element?(view, ~s(a[href="/console?new=caretaker"]), "set up caretaker")
    refute has_element?(view, "form[phx-submit=message]")
  end

  test "Ask resolves a custom-named caretaker role without a meta tag", %{conn: conn} do
    id = uid("manager-by-role")

    put_env!(:routines, [
      %{
        id: id,
        role: :caretaker,
        cron: "@daily",
        prompt: "coordinate",
        workspace: tmp_workspace!()
      }
    ])

    {:ok, view, _html} = live(conn, "/custode")
    assert has_element?(view, ~s(form[phx-hook=SubjectDraft][data-subject="#{id}"]))
    refute has_element?(view, "#manager-setup")
  end

  test "Ask and direct caretaker chat share paginated durable history after remount", %{
    conn: conn,
    caretaker: caretaker,
    worker: worker
  } do
    for n <- 1..23,
        do:
          completed_message!(caretaker.id, "history #{String.pad_leading(to_string(n), 2, "0")}.")

    completed_message!(worker.id, "project-only constraint")

    {:ok, manager, html} = live(conn, "/custode")
    assert html =~ "history 23."
    refute html =~ "history 01."
    refute html =~ "project-only constraint"
    html = manager |> element("#load-older-conversation") |> render_click()
    assert html =~ "history 01."
    refute has_element?(manager, "#load-older-conversation")

    {:ok, direct, html} = live(conn, "/agents/#{caretaker.id}/conversation")
    assert html =~ "history 23."
    assert has_element?(direct, ~s(form[phx-hook=SubjectDraft][data-subject="#{caretaker.id}"]))
    refute has_element?(direct, "#manager-context")
    {:ok, _project, html} = live(conn, "/agents/#{worker.id}/conversation")
    assert html =~ "project-only constraint"
    {:ok, _remounted, html} = live(conn, "/custode")
    assert html =~ "history 23."
  end

  test "forged plan targets cannot approve or reject a different gate", %{
    conn: conn,
    caretaker: caretaker,
    worker: worker
  } do
    propose!(caretaker, "review caretaker plan")
    propose!(worker, "review worker plan")
    [gate] = Gates.open_gates(caretaker.id)
    [other] = Gates.open_gates(worker.id)
    {:ok, view, _html} = live(conn, "/custode")

    assert render_click(view, "do_it", %{"action" => other.action_id}) =~ "no longer pending"
    assert render_click(view, "op", %{"op" => "approve"}) =~ "no longer pending"

    assert render_submit(view, "reject", %{
             "agent" => worker.id,
             "action" => gate.action_id,
             "reason" => "forged"
           }) =~ "no longer pending"

    assert [^gate] = Gates.open_gates(caretaker.id)
    assert [^other] = Gates.open_gates(worker.id)
  end

  test "a stale plan click cannot approve its replacement", %{conn: conn, caretaker: caretaker} do
    propose!(caretaker, "original plan")
    [gate] = Gates.open_gates(caretaker.id)
    {:ok, view, _html} = live(conn, "/custode")

    replacement =
      gate
      |> Ecto.Changeset.change(action_id: uid("replacement"), detail: "replacement plan")
      |> Repo.update!()

    assert render_click(view, "do_it", %{"action" => gate.action_id}) =~ "no longer pending"
    assert [^replacement] = Gates.open_gates(caretaker.id)
    assert render(view) =~ "replacement plan"
    assert render_click(view, "do_it", %{"action" => gate.action_id}) =~ "no longer pending"
    assert [^replacement] = Gates.open_gates(caretaker.id)
  end

  test "caretaker activity refreshes and preserves the away window", %{
    conn: conn,
    caretaker: caretaker
  } do
    Custode.Presence.set(:away)
    on_exit(fn -> Custode.Presence.set(:auto) end)
    {:ok, view, _html} = live(conn, "/custode")
    assert has_element?(view, "#custode-did", "while you were away")

    entry =
      Custode.Feed.record(%{
        event: "roster_added",
        agent: caretaker.id,
        summary: "new project added"
      })

    send(view.pid, {:feed_entry, entry})
    assert view |> element("#custode-did") |> render() =~ "new project added"
  end

  test "a correlated approval has one set of plan controls", %{conn: conn, caretaker: caretaker} do
    message = completed_message!(caretaker.id, "plan my projects")

    message
    |> Ecto.Changeset.change(status: "waiting_for_approval", completed_at: nil)
    |> Repo.update!()

    propose!(caretaker, "bounded project plan")
    {:ok, view, _html} = live(conn, "/custode")
    assert has_element?(view, "#custode-will")
    refute has_element?(view, "#conversation-actions")
  end

  test "an offline caretaker plan offers recovery instead of claiming it can approve", %{
    conn: conn,
    caretaker: caretaker
  } do
    gate =
      Repo.insert!(%Gates.Gate{
        agent_id: caretaker.id,
        kind: "approval",
        action_id: uid("departed"),
        detail: "review project priorities"
      })

    {:ok, view, _html} = live(conn, "/custode")
    assert has_element?(view, "#custode-will", "review project priorities")
    refute has_element?(view, "button[phx-click=do_it]")

    assert view |> element("button[phx-click=recover_plan]") |> render_click() =~
             "approval requeued for agent re-evaluation"

    assert Repo.get!(Gates.Gate, gate.id).status == "requeued"
  end

  defp completed_message!(agent, text) do
    {:ok, message, :created} =
      OperatorMessages.submit(
        agent,
        text,
        [actor: %{kind: :operator, id: "manager-test"}, via: :liveview],
        fn _message -> {:ok, :delivered} end
      )

    message
    |> Ecto.Changeset.change(
      status: "completed",
      result: %{"output" => "Recorded #{text}"},
      completed_at: DateTime.utc_now()
    )
    |> Repo.update!()
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
