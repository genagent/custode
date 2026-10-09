defmodule CustodeWeb.ConsoleLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks
  alias Custode.Availability.Collectors.Claude, as: ClaudeUsage
  alias Custode.GitHub.Cache
  alias Custode.Workflow
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run
  alias CustodeWeb.Console.Item
  alias CustodeWeb.Console.Rail

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("console-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    # the rail draws the whole fleet, so the whole fleet has to be this test's
    Custode.Repo.query!("DELETE FROM asks")
    Custode.Repo.query!("DELETE FROM gates")
    Custode.Repo.query!("DELETE FROM disowned_prs")
    # workflow launches and parked runs are subjects in the rail too (#447)
    Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
    Custode.Repo.query!("DELETE FROM workflow_runs")
    Custode.Host.reset()
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)

    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{id: uid("asker"), cron: "@daily", workspace: workspace, prompt: "sweep"},
      %{id: uid("sleeper"), cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    [asker, sleeper] = Custode.Routine.all()
    %{conn: build_conn(), asker: asker, sleeper: sleeper}
  end

  test "the rail groups the fleet by what it needs, and opens on what most needs you",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, _ask} = Asks.ask(asker.id, "is the uncommitted diff yours?")

    {:ok, _view, html} = live(conn, "/console")

    assert html =~ "needs you"
    assert html =~ "scheduled"
    assert html =~ asker.id
    assert html =~ sleeper.id
    # opened on the agent with the question, without being told to
    assert html =~ "is the uncommitted diff yours?"
    assert html =~ "#{asker.id} asked you"
  end

  test "one selected request owns its controls before subject history", %{
    conn: conn,
    asker: asker,
    sleeper: sleeper
  } do
    {:ok, ask} =
      Asks.ask(asker.id, "which branch should I use?", detail: "The release branch has diverged.")

    {:ok, next} = Asks.ask(sleeper.id, "which environment should I use?")
    {:ok, view, html} = live(conn, "/console/#{asker.id}")

    assert has_element?(
             view,
             "#selected-attention #ask-context",
             "The release branch has diverged."
           )

    assert has_element?(view, "#selected-attention form[phx-submit=op] textarea[name=text]")
    assert has_element?(view, "#selected-attention p", "raised")
    refute has_element?(view, "#subject-content h2", "which branch should I use?")
    refute has_element?(view, "#subject-content form[phx-submit=op]")
    assert length(Regex.scan(~r/id="reply-answer_ask-0"/, html)) == 1
    assert Regex.match?(~r/id="selected-attention".*id="subject-content"/s, html)
    assert has_element?(view, ~s(#selected-attention input[name=ask_id][value="#{ask.id}"]))

    view |> element(~s(#subject-rail a[href="/console/#{sleeper.id}"])) |> render_click()
    assert_patched(view, "/console/#{sleeper.id}")
    assert has_element?(view, "#selected-attention", "which environment should I use?")
    refute has_element?(view, "#selected-attention", "which branch should I use?")
    assert has_element?(view, ~s(#selected-attention input[name=ask_id][value="#{next.id}"]))
    assert Asks.get(ask.id).status == "open"
  end

  test "the fleet caretaker is visibly identified without leaving the normal rail", %{
    conn: conn
  } do
    workspace = tmp_workspace!()
    caretaker = uid("right-hand")
    worker = uid("worker")

    put_env!(:routines, [
      %{id: caretaker, profile: :caretaker, workspace: workspace},
      %{id: worker, cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    {:ok, view, _html} = live(conn, "/console")

    assert has_element?(
             view,
             ~s(#subject-rail a[data-rail-caretaker="true"][href="/console/#{caretaker}"]),
             "caretaker"
           )

    refute has_element?(
             view,
             ~s(#subject-rail a[data-rail-caretaker="true"][href="/console/#{worker}"])
           )
  end

  test "the selected running agent shows a live elapsed strip", %{conn: conn, sleeper: sleeper} do
    :ets.insert(
      :custode_run_clock,
      {sleeper.id, DateTime.add(DateTime.utc_now(), -65, :second)}
    )

    on_exit(fn -> :ets.delete(:custode_run_clock, sleeper.id) end)

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    assert has_element?(view, "#working-state", "working")
    assert view |> element("#working-state") |> render() =~ ~r/1m\d+s elapsed/

    :ets.insert(
      :custode_run_clock,
      {sleeper.id, DateTime.add(DateTime.utc_now(), -3_605, :second)}
    )

    send(view.pid, :inflight_tick)
    assert view |> element("#working-state") |> render() =~ "1h0m elapsed"

    :ets.delete(:custode_run_clock, sleeper.id)
    send(view.pid, :inflight_tick)
    refute has_element?(view, "#working-state")
  end

  test "the selected agent explains its pending inbox wake", %{conn: conn, sleeper: sleeper} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _wake} =
             Custode.InboxWakes.request(sleeper,
               now: now,
               debounce_seconds: 30
             )

    assert {:ok, _wake} =
             Custode.InboxWakes.request(sleeper,
               now: DateTime.add(now, 5, :second),
               debounce_seconds: 30
             )

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    assert has_element?(view, "#pending-inbox-wake", "inbox activity")
    assert has_element?(view, "#pending-inbox-wake", "2 notes pending")
    assert has_element?(view, "#pending-inbox-wake", "debouncing")

    Custode.Repo.query!(
      "UPDATE inbox_wakes SET blocked_by = 'running' WHERE routine_id = ?",
      [sleeper.id]
    )

    send(view.pid, {:status_changed, sleeper.id})

    assert has_element?(view, "#pending-inbox-wake", "held -- waiting for the current turn")

    Custode.Repo.query!(
      "UPDATE inbox_wakes SET blocked_by = 'provider_job' WHERE routine_id = ?",
      [sleeper.id]
    )

    send(view.pid, {:status_changed, sleeper.id})

    assert has_element?(
             view,
             "#pending-inbox-wake",
             "held -- waiting for the previous turn to finish"
           )

    refute render(view) =~ "provider job"

    Custode.Repo.query!(
      "UPDATE inbox_wakes SET spend_override = 1 WHERE routine_id = ?",
      [sleeper.id]
    )

    send(view.pid, {:status_changed, sleeper.id})

    assert has_element?(
             view,
             "#pending-inbox-wake",
             "held -- waiting for the previous turn to finish"
           )

    assert has_element?(view, "#pending-inbox-wake", "manual spend override granted")

    Custode.Repo.query!(
      "UPDATE inbox_wakes SET blocked_by = 'delivery_failed', spend_override = 0 WHERE routine_id = ?",
      [sleeper.id]
    )

    send(view.pid, {:status_changed, sleeper.id})

    assert has_element?(
             view,
             "#pending-inbox-wake",
             "held -- delivery failed; waiting for new activity or restart"
           )
  end

  # the design session's visual language (design/ui/2026-07-25-design-session)
  test "the page wears the custode themes, chosen before first paint, with a toggle",
       %{conn: conn} do
    html = conn |> get("/console") |> html_response(200)

    assert html =~ ~s([data-theme="paper"])
    assert html =~ ~s([data-theme="ink"])
    # the remembered choice, else the OS preference, set before the body renders
    assert html =~ ~s|localStorage.getItem("custode-theme")|
    assert html =~ "prefers-color-scheme: dark"
    assert html =~ "JetBrains+Mono"

    {:ok, view, _html} = live(conn, "/console")
    assert has_element?(view, ~s(#theme-toggle[aria-label="Dark theme"][aria-pressed=false]))
  end

  # #530: a fresh checkout has no roster, and used to boot the maintainer's
  test "an empty fleet says how to add an agent", %{conn: conn} do
    put_env!(:routines, [])

    {:ok, view, html} = live(conn, "/console")

    assert html =~ "No agents on this machine yet."
    assert html =~ "routines.example.toml"
    assert html =~ ~s(<nav aria-label="breadcrumb")
    # and the way to add one is on the page
    assert has_element?(view, "button[phx-click=new_open]")
    assert has_element?(view, "#first-agent-setup", "Fleet caretaker")
    assert has_element?(view, "button[phx-click=new_skip]", "Skip for now")
  end

  test "the console remains available and legacy agent URLs redirect into it", %{
    conn: conn,
    sleeper: sleeper
  } do
    {:ok, view, html} = live(conn, "/console")
    assert html =~ ~s(id="rail-filter")
    refute has_element?(view, ~s(header a[href="/fleet"]), "fleet")

    # the rail's links keep the subject's own address
    view |> element(~s(a[href="/console/#{sleeper.id}"])) |> render_click()
    assert_patched(view, "/console/#{sleeper.id}")

    assert conn |> get("/fleet") |> redirected_to() == "/"

    assert conn |> get("/agents/#{sleeper.id}") |> redirected_to() ==
             "/console/#{sleeper.id}"
  end

  test "the return digest stays dismissed through console refreshes", %{conn: conn} do
    previous = Application.get_env(:custode, :presence_override)
    Application.put_env(:custode, :presence_override, nil)
    on_exit(fn -> Application.put_env(:custode, :presence_override, previous) end)

    now = DateTime.utc_now()

    entries =
      for seconds <- [60, 60 + 3 * 3600] do
        Custode.Repo.insert!(%Custode.Feed.Entry{
          event: "presence",
          entry: "{}",
          at: DateTime.add(now, -seconds, :second)
        })
      end

    on_exit(fn -> Enum.each(entries, &Custode.Repo.delete!/1) end)

    {:ok, view, html} = live(conn, "/console")
    assert html =~ "while you were away"
    assert has_element?(view, "#away-digest-panel[data-digest-panel]", "Fleet digest")
    refute has_element?(view, "#away-digest > pre")
    refute has_element?(view, "#away-digest-panel details[open]")

    view |> element("#away-digest button", "Dismiss") |> render_click()
    refute render(view) =~ "while you were away"

    send(view.pid, {:feed_entry, %{}})
    refute render(view) =~ "while you were away"
  end

  test "advisor suggestions are actionable from the console", %{conn: conn, sleeper: sleeper} do
    on_exit(fn ->
      Custode.Repo.query!(
        "DELETE FROM feed_entries WHERE agent = ? AND event LIKE 'advisor_%'",
        [sleeper.id]
      )
    end)

    :ok =
      Custode.Feed.record(%{
        event: "advisor_suggestion",
        agent: sleeper.id,
        advisor: "advisor-cadence",
        field: "cron",
        current: "@hourly",
        proposed: "@daily",
        confidence: "medium",
        evidence: "most hourly sweeps found no work",
        summary: "suggests a quieter cadence"
      })

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    assert has_element?(view, "#advisor-suggestions", "most hourly sweeps found no work")
    assert has_element?(view, ~s(#advisor-suggestions a[href="/console/#{sleeper.id}"]))

    assert view
           |> element(~s(#advisor-suggestions a[href="/suggestions"]))
           |> render() =~ ~r/See all \d+/

    view
    |> element(
      ~s(#advisor-suggestions button[phx-click=dismiss_suggestion][phx-value-agent="#{sleeper.id}"][phx-value-field="cron"][phx-value-proposed="@daily"])
    )
    |> render_click()

    refute has_element?(view, "#advisor-suggestions", "most hourly sweeps found no work")
    assert render(view) =~ "dismissed"
  end

  test "selecting a subject shows its pane, and the rail filter narrows",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")

    assert has_element?(view, "#subject-content h1", sleeper.id)
    assert html =~ "@daily"
    assert has_element?(view, ~s(nav#subject-rail[phx-hook="SubjectRail"]))

    assert has_element?(
             view,
             ~s(nav#subject-rail a[data-rail-subject][aria-current="page"]),
             sleeper.id
           )

    assert has_element?(view, ~s(nav[aria-label="breadcrumb"] a[href="/console"]), "fleet")

    assert has_element?(
             view,
             ~s(nav[aria-label="breadcrumb"] a[href="/console/#{sleeper.id}"]),
             sleeper.id
           )

    assert has_element?(view, ~s(nav[aria-label="breadcrumb"] [aria-current="page"]), "next beat")

    html = view |> form("#rail-filter", %{"q" => "asker"}) |> render_change()
    assert html =~ ~s(href="/console/#{asker.id}")

    refute has_element?(
             view,
             ~s(nav[aria-label="subjects"] a[href="/console/#{sleeper.id}"])
           )
  end

  test "the rail's j and k shortcuts move among visible subjects and leave editors alone",
       %{conn: conn} do
    html = conn |> get("/console") |> html_response(200)

    assert html =~ ~S|const key = event.key.toLowerCase()|
    assert html =~ ~S|key !== "j" && key !== "k"|
    assert html =~ ~S|this.el.querySelectorAll("[data-rail-subject]")|
    assert html =~ ~S|subject.getClientRects().length > 0|
    assert html =~ ~S|subject.getAttribute("aria-current") === "page"|
    assert html =~ ~S|const next = subjects[start + step]|
    assert html =~ ~S|next.scrollIntoView({block: "nearest"})|
    assert html =~ ~S|input, textarea, select, button, [contenteditable='true'], [role='textbox']|
    assert html =~ ~S|window.removeEventListener("keydown", this.onKeydown)|
  end

  test "the command menu searches subjects, attention, results and labeled actions", %{
    conn: conn,
    asker: asker,
    sleeper: sleeper
  } do
    {:ok, _ask} = Asks.ask(asker.id, "which environment should I use?")
    Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "compared the options"})

    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ ~s(data-command-trigger)
    assert html =~ "Search commands (Cmd/Ctrl+K)"
    assert html =~ "Shift+Cmd/Ctrl+K"

    view |> element("[data-command-trigger]") |> render_click()
    assert has_element?(view, "#command-palette[role=dialog]")
    assert has_element?(view, "[data-command-option]", "compared the options")
    assert has_element?(view, "[data-command-option]", "which environment")
    assert has_element?(view, "[data-command-option]", "Pause #{sleeper.id}")
    refute has_element?(view, "[data-command-option]", "Approve")

    view |> form("#command-search", %{"q" => "compared options"}) |> render_change()
    assert has_element?(view, "[data-command-option]", "compared the options")
    refute has_element?(view, "[data-command-option]", "which environment")

    view |> element("button[phx-click=command_close]") |> render_click()
    refute has_element?(view, "#command-palette")
  end

  test "opening a result navigates to activity without starting work", %{
    conn: conn,
    sleeper: sleeper
  } do
    Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "saved the report"})
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    view |> element("[data-command-trigger]") |> render_click()

    view
    |> element("[data-command-option]", "saved the report")
    |> render_click()

    assert_redirected(view, "/console/#{sleeper.id}?tab=activity")
    refute_receive {:enqueued, _args, _meta}, 100
  end

  test "the command shortcut hook handles only modified k and palette navigation", %{conn: conn} do
    html = conn |> get("/console") |> html_response(200)

    assert html =~ ~S(event.metaKey || event.ctrlKey)
    assert html =~ ~S(event.shiftKey)
    assert html =~ ~s|document.querySelector("[data-command-trigger]")|
    assert html =~ ~s|event.key === "ArrowDown"|
    assert html =~ ~s|event.key === "ArrowUp"|
    assert html =~ ~s|event.key === "Enter" && event.target === this.input|
    assert html =~ ~s|window.location.assign("/?commands=open")|
  end

  test "quiet subjects collapse to one line and open when one is selected", %{conn: conn} do
    workspace = tmp_workspace!()
    scheduled = uid("scheduled")
    first_quiet = uid("quiet")
    second_quiet = uid("paused")

    put_env!(:routines, [
      %{id: scheduled, cron: "@daily", workspace: workspace, prompt: "sweep"},
      %{id: first_quiet, cron: :manual, workspace: workspace, prompt: "sweep"},
      %{id: second_quiet, cron: :manual, workspace: workspace, prompt: "sweep"}
    ])

    {:ok, view, _html} = live(conn, "/console/#{scheduled}")

    assert has_element?(view, "#quiet-subjects button[aria-expanded=false]")
    refute has_element?(view, "#quiet-subject-list")
    summary = view |> element("#quiet-subjects > button") |> render()
    # Other async tests may have temporary agents in the global fleet. The
    # row must report its actual numeric count and include this test's quiet
    # subjects; it need not pretend the process registry is test-local.
    assert summary =~ ~r/quiet\s*<\/span>\s*<span>\d+<\/span>/
    assert summary =~ first_quiet
    assert summary =~ second_quiet

    view |> element("#quiet-subjects > button") |> render_click()
    assert has_element?(view, "#quiet-subjects button[aria-expanded=true]")
    assert has_element?(view, "#quiet-subject-list")

    view |> element("#quiet-subjects > button") |> render_click()
    refute has_element?(view, "#quiet-subject-list")

    {:ok, selected_view, _html} = live(conn, "/console/#{first_quiet}")
    assert has_element?(selected_view, "#quiet-subjects button[aria-expanded=true]")

    assert has_element?(
             selected_view,
             "#quiet-subject-list a[aria-current=page]",
             first_quiet
           )
  end

  # #450: the agent page hides its composer for an offline agent
  test "an offline agent still has a message box, and it says what sending does",
       %{conn: conn, sleeper: sleeper} do
    subject = sleeper.id
    assert {:ok, prepared} = Custode.ConversationArcs.prepare(sleeper, :operator)
    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")

    assert html =~ "Start and send"
    assert html =~ "Sending starts a turn with your message."
    refute html =~ "offline -- the next beat starts it"
    assert html =~ prepared.arc_id
    assert html =~ "fresh/no_session"
    assert has_element?(view, ~s(form[phx-hook="SubjectDraft"][data-subject="#{sleeper.id}"]))
    assert has_element?(view, "[data-draft-state][hidden]", "unsent draft saved in this browser")
    assert has_element?(view, "button[data-discard-draft][hidden]", "Discard draft")

    html = view |> form("form[phx-submit=message]", %{"text" => "look at 42"}) |> render_submit()
    assert_push_event(view, "draft:clear", %{subject: ^subject})
    assert html =~ "started a turn with your message"
  end

  test "browser drafts persist per subject and accepted sends clear the visible composer",
       %{conn: conn} do
    html = conn |> get("/console") |> html_response(200)

    assert html =~ "custode-subject-draft:${encodeURIComponent(subject)}"
    assert html =~ "localStorage.setItem(draftKey(this.subject), this.input.value)"
    assert html =~ "localStorage.getItem(draftKey(this.subject))"
    assert html =~ ~s|setDraftInput(event.detail.subject, "")|
    assert html =~ ~s|input.dispatchEvent(new Event("input", {bubbles: true}))|
    assert html =~ "input.focus()"
    assert html =~ "Drafts belong to this browser profile"
  end

  test "an empty rejected submission does not clear the saved draft",
       %{conn: conn, sleeper: sleeper} do
    subject = sleeper.id
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    view |> form("form[phx-submit=message]", %{"text" => "   "}) |> render_submit()

    refute_push_event(view, "draft:clear", %{subject: ^subject})
  end

  test "prompt history restores multiline text into the composer without sending",
       %{conn: conn, sleeper: sleeper} do
    subject = sleeper.id
    prompt = "compare both approaches\nthen recommend one"
    :ok = Custode.Feed.record_prompted(sleeper.id, prompt)
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    view |> element("button[phx-click=tab][phx-value-tab=activity]") |> render_click()
    assert has_element?(view, "button[phx-click=restore_message]", "Edit and send again")

    view |> element("button[phx-click=restore_message]") |> render_click()
    assert_push_event(view, "draft:restore", %{subject: ^subject, text: ^prompt})

    assert [%{"event" => "prompted", "prompt" => ^prompt}] = Custode.Feed.for_agent(subject)
  end

  test "a question is answered in place, from the item pane",
       %{conn: conn, asker: asker} do
    {:ok, ask} = Asks.ask(asker.id, "staging or prod?")

    {:ok, view, _html} = live(conn, "/console/#{asker.id}")
    assert has_element?(view, ~s(nav[aria-label="breadcrumb"] [aria-current="page"]), "question")

    view
    |> form(~s(form[id^="reply-answer_ask-"]), %{"text" => "staging"})
    |> render_submit()

    assert %{status: "answered", answer: "staging"} = Asks.get(ask.id)
  end

  test "an ask can be dismissed with a blank reply and no reason",
       %{conn: conn, asker: asker} do
    {:ok, ask} = Asks.ask(asker.id, "is the access problem still happening?")
    {:ok, view, _html} = live(conn, "/console/#{asker.id}")

    assert has_element?(view, ~s(form[id^="reply-answer_ask-"] textarea[required]))
    refute has_element?(view, ~s(form[id^="dismiss-ask-"] [required]))

    html = view |> form(~s(form[id^="dismiss-ask-"])) |> render_submit()

    assert html =~ "dismissed"
    assert %{status: "dismissed", dismissal_reason: nil, answer: nil} = Asks.get(ask.id)
    refute has_element?(view, ~s(form[id^="dismiss-ask-"]))
    refute has_element?(view, ~s(form[id^="reply-answer_ask-"]))
    refute html =~ "#{asker.id} asked you"
  end

  test "a dismissal can record a reason without sending an answer",
       %{conn: conn, asker: asker} do
    {:ok, ask} = Asks.ask(asker.id, "can you authorize the token?")
    {:ok, view, _html} = live(conn, "/console/#{asker.id}")

    view
    |> form(~s(form[id^="dismiss-ask-"]), %{"reason" => "  fixed on the host  "})
    |> render_submit()

    assert %{status: "dismissed", dismissal_reason: "fixed on the host", answer: nil} =
             Asks.get(ask.id)
  end

  test "a stale dismissal cannot close the next ask after the signal refreshes",
       %{conn: conn, asker: asker} do
    {:ok, first} = Asks.ask(asker.id, "first question?")
    {:ok, second} = Asks.ask(asker.id, "second question?")
    {:ok, view, _html} = live(conn, "/console/#{asker.id}")

    assert has_element?(view, ~s(input[name=ask_id][value="#{first.id}"]))
    {:ok, _dismissed} = Asks.dismiss(first.id)

    eventually(fn ->
      assert has_element?(view, ~s(input[name=ask_id][value="#{second.id}"]))
    end)

    html =
      render_submit(view, "op", %{
        "op" => "dismiss_ask",
        "ask_id" => to_string(first.id),
        "reason" => "this was the first question"
      })

    assert html =~ "no longer pending"
    assert Asks.get(second.id).status == "open"
    assert has_element?(view, ~s(input[name=ask_id][value="#{second.id}"]))
  end

  test "a failing turn's item pane says why: category, count, retryable, the last detail",
       %{conn: conn, sleeper: sleeper} do
    detail = Enum.map_join(1..9, "\n", &"exit 1: Invalid API key, line #{&1}")

    for _n <- 1..2 do
      Custode.Feed.record(%{
        event: "turn_failed",
        agent: sleeper.id,
        summary: "turn failed",
        category: "auth_failed",
        detail: detail
      })
    end

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    pane = view |> element("#turn-failure") |> render()

    assert pane =~ "auth_failed"
    assert pane =~ "2 failed turns in a row"
    assert pane =~ "not retryable"
    assert pane =~ "Invalid API key, line 6"
    refute pane =~ "Invalid API key, line 7"
  end

  test "a failed doctor is on the console too", %{conn: conn} do
    Custode.Host.put_doctor({:failed, "claude auth: logged out"})
    on_exit(&Custode.Host.reset/0)

    {:ok, _view, html} = live(conn, "/console")
    assert html =~ "no agent can run: the boot doctor failed"
  end

  describe "the header" do
    # most of what the operator wants is a sentence to the caretaker (#451)
    test "tells custode from wherever you are, and says what happened", %{conn: conn} do
      workspace = tmp_workspace!()

      caretaker = uid("caretaker")

      put_env!(:routines, [
        %{id: caretaker, cron: "@daily", workspace: workspace, prompt: "sweep", tags: [:meta]},
        %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "sweep"}
      ])

      {:ok, view, _html} = live(conn, "/console")
      assert has_element?(view, "label[for=tell-input-0]", "Message #{caretaker}")
      assert has_element?(view, "input#tell-input-0[aria-describedby=tell-help-0]")
      assert has_element?(view, "#tell-help-0", "Press Enter to send.")

      html =
        view
        |> form("form[phx-submit=tell_custode]", %{"text" => "pause everything but mdbook-lint"})
        |> render_submit()

      # the caretaker is offline in a test, so it is started with the sentence
      assert html =~ "custode: started a turn with your message"
    end

    test "with no caretaker in the roster there is no box to type into", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")
      refute html =~ "phx-submit=\"tell_custode\""
    end

    test "presence toggles between present and a pinned away", %{conn: conn} do
      Custode.Presence.set(:present)
      on_exit(fn -> Custode.Presence.set(:auto) end)

      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(
               view,
               "button[phx-click=toggle_presence][aria-describedby=presence-help]",
               "Presence: present"
             )

      assert has_element?(view, "#presence-help", "Away silences them and stays pinned")
      assert has_element?(view, "#fleet-actions summary", "Fleet actions")
      assert has_element?(view, "#pause-all-help", "Pause every running agent.")
      assert has_element?(view, "#resume-all-help", "Resume paused agents.")
      assert has_element?(view, "#drain-help", "then stop Custode")

      assert has_element?(
               view,
               "button[phx-click=drain][data-confirm][aria-describedby=drain-help]"
             )

      html = view |> element("button[phx-click=toggle_presence]") |> render_click()
      assert html =~ "away"
      assert {:away, _at, {:pinned, :away}} = Custode.Presence.explain()
    end

    test "the brake is in the fleet menu and reports what it did", %{conn: conn} do
      id = start_stub_agent!()

      {:ok, view, _html} = live(conn, "/console")
      html = view |> element("button[phx-click=pause_all]") |> render_click()

      assert html =~ ~r/Paused \d+ agents?\./
      assert {:ok, :paused} = ObanClaude.Agent.await(id, :paused, 1_000)

      html = view |> element("button[phx-click=resume_all]") |> render_click()
      assert html =~ ~r/Resumed \d+ agents?\./
    end
  end

  test "the config tab says who the agent is, and the turns tab is honest when empty",
       %{conn: conn, sleeper: sleeper} do
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    html = view |> element("button[phx-value-tab=config]") |> render_click()
    assert html =~ "sweeps on"
    assert html =~ "@daily"
    assert html =~ "Standing orders"

    html = view |> element("button[phx-value-tab=turns]") |> render_click()
    assert html =~ "no machine log"
  end

  for {current_provider, current_model, current_effort, next_provider, next_model, next_effort} <-
        [
          {:claude, "haiku", "low", :codex, "gpt-5.6-sol", "high"},
          {:codex, "gpt-5.6-luna", "low", :claude, "sonnet", "high"}
        ] do
    test "a running #{current_provider} turn keeps its captured configuration while the routine changes",
         %{conn: conn} do
      current_provider = unquote(current_provider)
      current_model = unquote(current_model)
      current_effort = unquote(current_effort)
      next_provider = unquote(next_provider)
      next_model = unquote(next_model)
      next_effort = unquote(next_effort)
      id = uid("console-config")
      workspace = tmp_workspace!()

      configured = %{
        id: id,
        cron: :manual,
        workspace: workspace,
        working_dir: workspace,
        prompt: "inspect the captured configuration",
        provider: current_provider,
        model: current_model,
        effort: current_effort,
        mcp: false
      }

      put_env!(:routines, [configured])
      routine = Custode.Routine.get(id)
      current_revision = Custode.Routine.execution_revision(routine)

      assert {:ok, _pid} =
               Custode.Agents.start_agent(
                 id,
                 current_provider,
                 Custode.Routine.agent_config(routine)
               )

      on_exit(fn ->
        case Custode.Agents.status(id, current_provider) do
          {:ok, :offline} -> :ok
          {:ok, _state} -> Custode.Agents.stop_agent(id, current_provider)
        end

        Custode.Repo.query!("DELETE FROM oban_jobs WHERE json_extract(meta, '$.agent_id') = ?", [
          id
        ])
      end)

      assert :processing = Custode.Agents.submit_prompt(id, "use the old contract")

      import Ecto.Query, only: [from: 2]

      [turn] =
        Custode.Repo.all(
          from(j in Oban.Job,
            where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^id
          )
        )

      assert turn.args["model"] == current_model
      assert turn.meta["config_revision"] == current_revision

      Application.put_env(:custode, :routines, [
        %{
          configured
          | provider: next_provider,
            model: next_model,
            effort: next_effort
        }
      ])

      desired_revision = id |> Custode.Routine.get() |> Custode.Routine.execution_revision()
      assert desired_revision != current_revision

      {:ok, view, _html} = live(conn, "/console/#{id}")

      summary = view |> element("#subject-execution-facts") |> render()
      assert summary =~ to_string(current_provider)
      assert summary =~ current_model
      assert summary =~ "#{current_effort} effort"
      refute summary =~ next_model

      transition = view |> element("#subject-config-transition") |> render()
      assert transition =~ "active turn:"
      assert transition =~ to_string(current_provider)
      assert transition =~ current_model
      assert transition =~ "next turn:"
      assert transition =~ to_string(next_provider)
      assert transition =~ next_model
      assert transition =~ "#{next_effort} effort"

      view |> element("button[phx-value-tab=config]") |> render_click()
      active = view |> element("#active-turn-config") |> render()
      desired = view |> element("#desired-turn-config") |> render()
      assert active =~ current_model
      assert active =~ String.slice(current_revision, 0, 12)
      refute active =~ next_model
      assert desired =~ next_model
      assert desired =~ "#{next_effort} effort"

      assert has_element?(
               view,
               ~s(#desired-turn-config[data-config-revision="#{desired_revision}"])
             )

      view |> element("button[phx-value-tab=turns]") |> render_click()
      captured = view |> element("#turn-contract-#{turn.id}") |> render()
      assert captured =~ current_model
      assert captured =~ "#{current_effort} effort"
      refute captured =~ next_model

      assert has_element?(
               view,
               ~s(#turn-contract-#{turn.id}[data-config-revision="#{current_revision}"])
             )
    end
  end

  # seen on the live fleet: an offline agent's "last said" was three identical
  # sensor pings
  test "last said is what the agent said, and sensor pings are only a footnote",
       %{conn: conn, sleeper: sleeper} do
    for _n <- 1..3 do
      Custode.Feed.record(%{event: "sensor", agent: sleeper.id, summary: "ci: nothing new"})
    end

    {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ "nothing yet from the agent. Last sensor: ci: nothing new"

    Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "3 todos queued"})

    {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ "3 todos queued"
    refute html =~ "nothing yet"
  end

  # seen on the live fleet 2026-09-20: mcp-proxy's "last said" led with an
  # 8-hour-old gate_aging notice and an inbox drop, and its newest turn was not
  # on the page at all
  test "last said is the agent's newest words, not custode's notices about it",
       %{conn: conn, sleeper: sleeper} do
    for n <- 1..4 do
      Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "sweep number #{n}"})
    end

    Custode.Feed.record(%{event: "gate_aging", agent: sleeper.id, summary: "a gate has waited"})
    Custode.Feed.record(%{event: "inbox_note", agent: sleeper.id, summary: "note dropped"})

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    said = view |> element("#last-said") |> render()

    # the newest three, newest first
    assert said =~ ~r/sweep number 4.*sweep number 3.*sweep number 2/s
    refute said =~ "sweep number 1"
    refute said =~ "a gate has waited"
    refute said =~ "note dropped"

    # nothing is lost: the notices are on the activity tab, newest first
    html = view |> element("button[phx-value-tab=activity]") |> render_click()
    assert html =~ ~r/note dropped.*a gate has waited.*sweep number 4/s
  end

  test "the notebook tab reads older journal entries and shows what was done",
       %{conn: conn, sleeper: sleeper} do
    for n <- 1..11 do
      {:ok, _entry} =
        Custode.Notebook.journal_append(sleeper.id, "## entry-#{n}-title\n\nbody #{n}")
    end

    {:ok, keep} = Custode.Notebook.todo_add(sleeper.id, "still owed")
    {:ok, finished} = Custode.Notebook.todo_add(sleeper.id, "finished last week")
    {:ok, _todo} = Custode.Notebook.todo_complete(finished.id)

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    html = view |> element("button[phx-value-tab=notebook]") |> render_click()

    # the ten newest, and a way to the eleventh
    assert html =~ "entry-11-title"
    assert html =~ "entry-2-title"
    refute html =~ "entry-1-title"

    html = view |> element("button[phx-click=journal_older]") |> render_click()
    assert html =~ "entry-1-title"
    refute has_element?(view, "button[phx-click=journal_older]")

    # the open list is only what is owed; what was done is one click under it
    done = view |> element("#done-todos") |> render()
    assert done =~ "finished last week"
    refute done =~ "still owed"
    assert html =~ keep.text
  end

  test "the rail filter matches a routine's tags, repository and state, not only its name",
       %{conn: conn, asker: asker} do
    workspace = tmp_workspace!()
    rusty = uid("crate")
    plain = uid("other")

    put_env!(:routines, [
      %{id: rusty, cron: "@daily", workspace: workspace, prompt: "x", tags: [:rust, :external]},
      %{id: plain, cron: "@daily", workspace: workspace, prompt: "x", repo: "acme/widgets"},
      %{id: asker.id, cron: "@daily", workspace: workspace, prompt: "x"}
    ])

    {:ok, _ask} = Asks.ask(asker.id, "is the diff yours?")
    {:ok, view, _html} = live(conn, "/console")

    narrowed = fn q -> view |> form("#rail-filter", %{"q" => q}) |> render_change() end

    html = narrowed.("RUST")
    assert html =~ ~s(href="/console/#{rusty}")
    refute html =~ ~s(href="/console/#{plain}")

    html = narrowed.("acme/wid")
    assert html =~ ~s(href="/console/#{plain}")
    refute html =~ ~s(href="/console/#{rusty}")

    # a state word finds what is in that state
    html = narrowed.("asked you")
    assert html =~ ~s(href="/console/#{asker.id}")
    refute html =~ ~s(href="/console/#{rusty}")
  end

  # design session, question-inline.png: "or just say"
  test "a question's suggested replies are one-click answers, and only those can be sent",
       %{conn: conn, asker: asker} do
    {:ok, ask} =
      Asks.ask(asker.id, "PR #400 is red and I filed it as yours. Take it over?",
        detail: "sweeping open PRs; #400 touches your LSP config",
        replies: ["Yes, take it over", "No, leave it to me", "   ", String.duplicate("x", 200)]
      )

    {:ok, view, html} = live(conn, "/console/#{asker.id}")

    assert html =~ "sweeping open PRs; #400 touches your LSP config"
    replies = view |> element("#suggested-replies") |> render()
    assert replies =~ "Yes, take it over"
    assert replies =~ "No, leave it to me"
    # blank and over-long suggestions were dropped when the ask was filed
    assert length(Regex.scan(~r/phx-click="reply"/, replies)) == 2

    # an index the agent never offered sends nothing
    assert render_click(view, "reply", %{"index" => "7"}) =~ "no longer pending"
    assert [%{status: "open"}] = Asks.open()

    view |> element(~s(button[phx-click=reply][phx-value-index="1"])) |> render_click()
    assert Asks.open() == []
    assert %{answer: "No, leave it to me"} = Custode.Repo.get!(Asks.Ask, ask.id)
  end

  test "an ask with no suggestions is answered by typing, as before",
       %{conn: conn, asker: asker} do
    {:ok, _ask} = Asks.ask(asker.id, "is the diff yours?")
    {:ok, view, _html} = live(conn, "/console/#{asker.id}")

    refute has_element?(view, "#suggested-replies")
    refute has_element?(view, "#ask-context")
    assert has_element?(view, "textarea[name=text]")
  end

  test "the item pane points at the next subject that needs you, and only then",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, _ask} = Asks.ask(asker.id, "is the diff yours?")

    # nothing else needs the operator while they look at the one that does
    {:ok, view, _html} = live(conn, "/console/#{asker.id}")
    refute has_element?(view, "#next-up")

    # from anywhere else, the one that does is a click away
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    next_up = view |> element("#next-up") |> render()
    assert next_up =~ asker.id
    assert next_up =~ "asked you a question"

    html = view |> element("#next-up a") |> render_click()
    assert html =~ "is the diff yours?"
    assert_patched(view, "/console/#{asker.id}")
  end

  # seen on the live fleet 2026-09-20: 19 of mcp-proxy's last 30 entries were
  # the same "nothing new" sensor ping
  test "the activity tab draws a run of identical sensor arrivals once",
       %{conn: conn, sleeper: sleeper} do
    ping = %{event: "sensor", agent: sleeper.id, sensor_id: "ci", summary: "ci: nothing new"}

    Custode.Feed.record(ping)
    Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "swept the backlog"})
    for _n <- 1..4, do: Custode.Feed.record(ping)

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    view |> element("button[phx-value-tab=activity]") |> render_click()
    activity = view |> element("#activity") |> render()

    # newest first: the run of four, the turn, then the lone ping before it
    assert activity =~ ~r/×4 since.*swept the backlog.*ci: nothing new/su
    assert length(Regex.scan(~r/ci: nothing new/, activity)) == 2
    # a short feed has nothing further back
    refute has_element?(view, "button[phx-click=feed_older]")
  end

  test "show older reads further back, and a new subject starts over",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    # distinct summaries and events that never collapse
    for n <- 1..151 do
      Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "sweep-#{n}-end"})
    end

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    html = view |> element("button[phx-value-tab=activity]") |> render_click()

    assert html =~ "sweep-151-end"
    assert html =~ "sweep-2-end"
    refute html =~ "sweep-1-end"

    html = view |> element("button[phx-click=feed_older]") |> render_click()
    assert html =~ "sweep-1-end"
    # everything is on the page now, so there is nothing older to offer
    refute has_element?(view, "button[phx-click=feed_older]")

    # the longer read belongs to the subject it was asked for
    view |> element(~s(a[href="/console/#{asker.id}"])) |> render_click()
    view |> element(~s(a[href="/console/#{sleeper.id}"])) |> render_click()
    html = render(view)
    refute html =~ "sweep-1-end"
  end

  test "a scheduled agent says when it next runs, in the rail and in the item pane",
       %{conn: conn, sleeper: sleeper} do
    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")

    # @daily is at most a day away, so the wait is always hours, minutes or
    # seconds, never a bare cron string
    assert view
           |> element(~s(nav[aria-label="subjects"] a[href="/console/#{sleeper.id}"]))
           |> render() =~
             ~r/>\s*\d+[hms]\s*</

    assert html =~ ~r/runs in <span class="font-mono">\d+[hms]<\/span>/
  end

  test "a workflow launch is a subject in the rail, and is decided from the item pane (#447)",
       %{conn: conn, sleeper: sleeper} do
    workflow =
      Workflow.new!(uid("console-wf"), [
        %Workflow.Stage{
          name: :mine,
          nodes: [%Workflow.Node{name: :spec, prompt: "do it", schema: %{}}]
        }
      ])

    Application.put_env(:custode, :extra_workflows, %{workflow.name => workflow})

    on_exit(fn ->
      Application.delete_env(:custode, :extra_workflows)
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
      Custode.Repo.query!("DELETE FROM workflow_runs")
      Custode.Repo.query!("DELETE FROM oban_jobs WHERE worker = 'Custode.Workflow.NodeJob'")
    end)

    {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo")

    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ "awaits your launch approval"

    # the subject holds a slash, so the rail link has to encode it to stay one
    # path segment
    html = view |> element("nav[aria-label=subjects] a", workflow.name) |> render_click()
    assert html =~ "wants your approval to launch"
    workflow_subject = "#{workflow.name} on owner/repo"
    workflow_path = Rail.subject_path(workflow_subject)

    assert has_element?(
             view,
             ~s(nav[aria-label="breadcrumb"] a[href="#{workflow_path}"]),
             workflow_subject
           )

    assert has_element?(view, ~s(nav[aria-label="breadcrumb"] [aria-current="page"]), "launch")

    # a workflow signal is not an agent: nothing to beat, pause or talk to
    assert html =~ "not an agent"
    refute html =~ "Beat now"
    refute html =~ ~s(phx-click="pause")
    refute html =~ ~s(phx-submit="message")

    view |> element("button[phx-value-op=approve_launch]") |> render_click()

    assert Launch.pending() == []
    assert [%{workflow: name, status: "running"}] = Run.list()
    assert name == workflow.name
  end

  describe "the item pane" do
    # on the live fleet "main is red" arrived with nothing to click
    test "a signal's evidence is a link when the subject has a repository" do
      html =
        render_component(&Item.evidence/1,
          item: {:branch, "main"},
          repo: "joshrotenberg/tower-mcp"
        )

      assert html =~ "failing runs on main"

      assert html =~
               "https://github.com/joshrotenberg/tower-mcp/actions?query=branch%3Amain+is%3Afailure"

      html =
        render_component(&Item.evidence/1,
          item: {:prs, [400, 429]},
          repo: "joshrotenberg/mdbook-lint"
        )

      assert html =~ "https://github.com/joshrotenberg/mdbook-lint/pull/400"
      assert html =~ "#429"
    end

    test "evidence with no repository behind it draws nothing" do
      assert render_component(&Item.evidence/1,
               item: {:branch, "main"},
               repo: nil
             ) == ""
    end

    # the part of #447 the inbox could not carry: prune a batch where you approve it
    test "a drafted batch is pruned in place: drop, then keep", %{conn: conn, sleeper: sleeper} do
      batch = uid("batch")

      [first, _second] =
        for title <- ["chore: bump deps", "fix: flaky pool test"] do
          Custode.Repo.insert!(%Custode.Drafts.Draft{
            batch_id: batch,
            routine_id: sleeper.id,
            repo: "acme/widgets",
            title: title,
            body: "evidence for " <> title
          })
        end

      {:ok, view, html} = live(conn, "/console/#{sleeper.id}")
      assert html =~ "drafted issues: 2 of 2 kept"
      assert html =~ "fix: flaky pool test"

      html =
        view
        |> element(~s(button[phx-click=drop_draft][phx-value-id="#{first.id}"]))
        |> render_click()

      assert html =~ "drafted issues: 1 of 2 kept"

      html = view |> element("button[phx-click=keep_draft]") |> render_click()
      assert html =~ "drafted issues: 2 of 2 kept"
    end
  end

  test "the notebook tab is a working one: a todo can be done and a memory forgotten",
       %{conn: conn, sleeper: sleeper} do
    {:ok, _todo} = Custode.Notebook.todo_add(sleeper.id, "bench the pooled path")
    Custode.Memory.remember(sleeper.id, "watch-item", "pool flakes on macOS CI")

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    html = view |> element("button[phx-value-tab=notebook]") |> render_click()

    assert html =~ "bench the pooled path"
    assert html =~ "pool flakes on macOS CI"

    view |> element("button[phx-click=todo_done]") |> render_click()
    # off the open list, and onto the done one
    refute view |> element("#open-todos") |> render() =~ "bench the pooled path"
    assert view |> element("#done-todos") |> render() =~ "bench the pooled path"

    html = view |> element("button[phx-click=forget_memory]") |> render_click()
    refute html =~ "pool flakes on macOS CI"
  end

  test "a long notebook memory folds behind an explicit disclosure", %{
    conn: conn,
    sleeper: sleeper
  } do
    value = String.duplicate("bounded context stays readable. ", 20)
    Custode.Memory.remember(sleeper.id, "long-context", value)
    memory = Enum.find(Custode.Memory.recall(sleeper.id), &(&1.key == "long-context"))

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    view |> element("button[phx-value-tab=notebook]") |> render_click()

    disclosure = view |> element("#memory-#{memory.id}[data-foldable-text]") |> render()
    assert disclosure =~ "Show more"
    assert disclosure =~ "Show less"
    assert disclosure =~ value
  end

  # seeing many things at once is the point: a rail of bare names made every
  # one of them a click
  test "the rail says what is wrong for a subject that needs you, and stays quiet otherwise",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, _ask} = Asks.ask(asker.id, "which env?")

    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
    rail = view |> element("nav[aria-label=subjects]") |> render()

    assert rail =~ "asked you a question"
    # a scheduled agent pays no second line
    refute rail =~ "next beat"
  end

  describe "the panel tab" do
    test "an agent with no panel says so", %{conn: conn, sleeper: sleeper} do
      {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
      html = view |> element("button[phx-value-tab=panel]") |> render_click()
      assert html =~ "this agent keeps no panel"
    end

    # the same boundary the agent page holds (#100): there is ONE sandbox
    # component, and the console must not grow a second way to draw agent HTML
    test "proposed HTML is previewed in the sandbox, then approved from here",
         %{conn: conn, sleeper: sleeper} do
      {:ok, _} = Custode.Panels.set(sleeper.id, "<script>alert(1)</script><b>swarm map</b>")

      {:ok, view, html} = live(conn, "/console/#{sleeper.id}")
      # the tab carries a count while a panel waits on the operator
      assert html =~ ~r/Panel<span[^>]*>\s*1/

      html = view |> element("button[phx-value-tab=panel]") |> render_click()
      assert html =~ "proposed panel"
      assert html =~ ~s(sandbox="")
      assert html =~ "srcdoc="
      refute html =~ "<script>alert(1)</script>"

      html = view |> element("button[phx-click=approve_panel]") |> render_click()
      refute html =~ "proposed panel"
      assert Custode.Panels.current(sleeper.id) =~ "swarm map"
    end

    test "the markdown panel an agent curates for the operator is shown",
         %{conn: conn, sleeper: sleeper} do
      Custode.Memory.remember(
        sleeper.id,
        "panel",
        "| repo | state |\n|---|---|\n| tower | green |"
      )

      {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
      html = view |> element("button[phx-value-tab=panel]") |> render_click()

      assert html =~ "notes to you"
      assert html =~ "<table>"
    end
  end

  # #485: the work tab draws the same panel the agent page does, and the same
  # repo GitHub refuses used to leave it blank.
  @tag :capture_log
  test "the work tab says when GitHub refuses the subject's repository", %{conn: conn} do
    repo = "acme/" <> uid("refused")
    on_exit(fn -> Cache.forget(repo) end)

    refusal = %GhEx.Error{
      status: 403,
      message: "Resource protected by organization SAML enforcement"
    }

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, refusal}))

    routine = routine_fixture!(tmp_workspace!(), %{repo: repo})

    {:ok, view, _html} = live(conn, "/console/#{routine.id}")
    view |> element("button[phx-value-tab=work]") |> render_click()

    # the first render races the async fetch; the failure broadcasts, and the
    # console re-pulls on it
    html =
      eventually(fn ->
        html = render(view)
        assert html =~ "GitHub refused this repository: HTTP 403: Resource protected"
        html
      end)

    assert html =~ repo
  end

  describe "the attention tab is the one-page summary of a subject" do
    test "the agent's own read is on it, with when it was written",
         %{conn: conn, sleeper: sleeper} do
      {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
      refute html =~ "agent's own read"

      :ok =
        Custode.Memory.remember(sleeper.id, "panel", "**Watch**\n\n- the macOS perf test flakes")

      {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")
      read = view |> element("#own-read") |> render()

      assert read =~ "self-curated"
      assert read =~ ~r/written <span[^>]*>\d+s ago/
      assert read =~ "<strong>Watch</strong>"
      assert read =~ "the macOS perf test flakes"
    end

    test "open pull requests and the top of the backlog are on it", %{conn: conn} do
      repo = "acme/" <> uid("summary")
      on_exit(fn -> Cache.forget(repo) end)

      issues =
        for n <- 1..7 do
          %{number: 400 + n, title: "backlog item #{n}", url: "https://x/#{n}", at: nil}
        end

      overview = %{
        open_issues: %{total: 7, items: issues},
        closed_issues: %{total: 0, items: []},
        open_prs: %{
          total: 1,
          items: [
            %{
              number: 589,
              title: "convert ignore to no_run",
              url: "https://x",
              at: nil,
              draft: true,
              checks: "FAILURE"
            }
          ]
        },
        merged_prs: %{total: 0, items: []}
      }

      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

      routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
      {:ok, view, _html} = live(conn, "/console/#{routine.id}")

      # the first render races the async fetch; the broadcast settles it
      work = eventually(fn -> view |> element("#open-work") |> render() end)

      assert work =~ "1 pull request, 7 issues"
      assert work =~ "convert ignore to no_run"
      assert work =~ "bg-error"
      assert work =~ "backlog item 5"
      refute work =~ "backlog item 6"

      # the rest is one click away, and nothing left the work tab
      html = view |> element("#open-work button", "All 7 on the work tab") |> render_click()
      assert html =~ "backlog item 7"
    end

    test "work counts read naturally for zero, one and many", %{conn: conn} do
      for {prs, issues, expected} <- [
            {0, 1, "0 pull requests, 1 issue"},
            {2, 0, "2 pull requests, 0 issues"}
          ] do
        repo = "acme/" <> uid("count-copy")
        on_exit(fn -> Cache.forget(repo) end)
        item = %{number: 1, title: "Tracked work", url: "https://example.com", at: nil}

        overview = %{
          open_issues: %{total: issues, items: List.duplicate(item, issues)},
          closed_issues: %{total: 0, items: []},
          open_prs: %{total: prs, items: List.duplicate(item, prs)},
          merged_prs: %{total: 0, items: []}
        }

        overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
        put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))
        routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
        {:ok, view, _html} = live(conn, "/console/#{routine.id}")

        eventually(fn -> assert has_element?(view, "#open-work h3", expected) end)
      end
    end

    test "a subject with no repository and no panel draws neither section",
         %{conn: conn, sleeper: sleeper} do
      {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
      refute html =~ ~s(id="own-read")
      refute html =~ ~s(id="open-work")
    end
  end

  describe "the item pane's checks (#450)" do
    defmodule ChecksOps do
      @moduledoc false
      def pr_checks(_owner, _repo, 637) do
        {:ok,
         %{
           sha: "abc",
           checks: [
             %{
               id: 638,
               name: "fmt",
               status: "completed",
               conclusion: "success",
               url: "https://x/fmt"
             },
             %{
               id: 637,
               name: "test (ubuntu)",
               status: "completed",
               conclusion: "failure",
               url: "https://x/t"
             },
             %{
               id: 636,
               name: "lint",
               status: "completed",
               conclusion: "failure",
               url: "https://x/lint"
             },
             %{id: 639, name: "docs", status: "in_progress", conclusion: nil, url: nil}
           ]
         }}
      end

      def pr_checks(_owner, _repo, _number), do: {:error, "github: 502"}

      def job_log_tail(_owner, _repo, 636) do
        send(Application.fetch_env!(:custode, :checks_test_pid), {:job_log_tail, 636})
        {:error, "GitHub Actions logs unavailable"}
      end

      def job_log_tail(_owner, _repo, job_id) do
        send(Application.fetch_env!(:custode, :checks_test_pid), {:job_log_tail, job_id})
        {:ok, "Compiling 42 files\n** (RuntimeError) expected true, got false"}
      end
    end

    setup %{conn: conn} do
      repo = "acme/" <> uid("red")
      on_exit(fn -> Cache.forget(repo) end)

      red = fn number ->
        %{number: number, title: "pr #{number}", url: "https://x", at: nil, checks: "FAILURE"}
      end

      overview = %{
        open_issues: %{total: 0, items: []},
        closed_issues: %{total: 0, items: []},
        merged_prs: %{total: 0, items: []},
        open_prs: %{total: 2, items: [red.(637), red.(640)]}
      }

      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))
      put_env!(:repo_ops, ChecksOps)
      put_env!(:checks_test_pid, self())

      routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
      :ok = Custode.Repository.ensure_served(repo, routine.id)
      # the signal is resolved from the cached overview, so it has to be there
      eventually(fn -> assert {:ok, _overview} = Custode.GitHub.overview(repo) end)

      %{conn: conn, routine: routine}
    end

    test "each pull request the signal points at lists its checks, failed first",
         %{conn: conn, routine: routine} do
      {:ok, view, _html} = live(conn, "/console/#{routine.id}")

      html =
        eventually(fn ->
          html = render(view)
          refute html =~ "reading checks..."
          html
        end)

      assert html =~ ~r/lint.*failure.*test \(ubuntu\).*failure.*docs.*in_progress.*fmt.*success/s
      assert html =~ ~s(href="https://x/t")
      assert html =~ ~s(id="check-log-637")
      assert html =~ "expected true, got false"
      assert_receive {:job_log_tail, 637}
      assert_receive {:job_log_tail, 636}
      refute html =~ ~s(id="check-log-636")
      refute_receive {:job_log_tail, 638}
      refute_receive {:job_log_tail, 639}
      # one PR's read failing does not take the other's rows with it
      assert html =~ ~r/checks unavailable: [^<]*502/
    end
  end

  describe "the work tab" do
    setup %{conn: conn} do
      workspace = tmp_workspace!()
      repo = "acme/" <> uid("widgets")

      put_env!(:routines, [
        %{id: uid("keeper"), cron: "@daily", workspace: workspace, prompt: "sweep", repo: repo}
      ])

      [keeper] = Custode.Routine.all()
      on_exit(fn -> Custode.Repo.query!("DELETE FROM disowned_prs") end)
      %{conn: conn, keeper: keeper, repo: repo}
    end

    # CLI only until the console: `mix custode disown`
    test "a pull request is disowned with a reason, listed, and reclaimed",
         %{conn: conn, keeper: keeper, repo: repo} do
      {:ok, view, _html} = live(conn, "/console/#{keeper.id}")
      view |> element("button[phx-value-tab=work]") |> render_click()

      html =
        view
        |> form("form[phx-submit=disown]", %{"number" => "#400", "reason" => "my LSP config fix"})
        |> render_submit()

      assert html =~ "disowned #400"
      assert html =~ "my LSP config fix"
      assert %{reason: "my LSP config fix", agent_id: agent} = Custode.Disowned.get(repo, 400)
      assert agent == keeper.id

      html = view |> element("button[phx-click=reclaim]") |> render_click()
      assert html =~ "reclaimed #400"
      assert Custode.Disowned.get(repo, 400) == nil
    end

    test "something that is not a PR number is refused, not stored",
         %{conn: conn, keeper: keeper, repo: repo} do
      {:ok, view, _html} = live(conn, "/console/#{keeper.id}")
      view |> element("button[phx-value-tab=work]") |> render_click()

      html =
        view
        |> form("form[phx-submit=disown]", %{"number" => "the red one", "reason" => ""})
        |> render_submit()

      assert html =~ "not_a_pr_number"
      assert Custode.Disowned.numbers(repo) |> Enum.empty?()
    end
  end

  # CLI only until the console: `mix custode drain`
  test "drain is in the fleet menu, pauses the queues and hands the wait to a task",
       %{conn: conn} do
    test_pid = self()
    put_env!(:drain_fun, fn opts -> send(test_pid, {:drain_called, opts}) end)

    {:ok, view, _html} = live(conn, "/console")
    html = view |> element("button[phx-click=drain]") |> render_click()

    assert html =~ "Draining: queues paused"
    assert_receive {:drain_called, _opts}, 1_000
  end

  describe "editing an agent from the config tab" do
    setup do
      roster = Path.join(System.tmp_dir!(), uid("console-roster") <> ".toml")
      System.put_env("CUSTODE_CONFIG", roster)
      previous = Application.get_env(:custode, :routines)

      on_exit(fn ->
        System.delete_env("CUSTODE_CONFIG")
        File.rm(roster)
        Application.put_env(:custode, :routines, previous)
      end)

      %{roster: roster}
    end

    defp open_edit(conn, id) do
      {:ok, view, _html} = live(conn, "/console/#{id}")
      view |> element("button[phx-value-tab=config]") |> render_click()
      html = view |> element("button[phx-click=edit_open]") |> render_click()
      {view, html}
    end

    test "opens on the raw entry, saves through the write-back, and is live without a restart",
         %{conn: conn, sleeper: sleeper, roster: roster} do
      {view, html} = open_edit(conn, sleeper.id)

      assert html =~ ~s(value="@daily")
      # no roster file yet: the form says a save moves the roster into one
      assert html =~ "Saving migrates your roster"

      html =
        view
        |> form("#edit-routine", %{
          "routine" => %{"daily_budget_usd" => "75.5", "cron" => "@weekly"}
        })
        |> render_submit()

      assert html =~ "saved: live at the next minute"
      assert File.read!(roster) =~ "daily_budget_usd = 75.5"
      assert %{daily_budget_usd: 75.5, cron: "@weekly"} = Custode.Routine.get(sleeper.id)
    end

    test "a value that does not parse refuses the save and keeps what was typed",
         %{conn: conn, sleeper: sleeper} do
      {view, _html} = open_edit(conn, sleeper.id)

      html =
        view
        |> form("#edit-routine", %{"routine" => %{"max_turns" => "plenty"}})
        |> render_submit()

      assert html =~ "refused: max_turns must be an integer"
      assert html =~ ~s(value="plenty")
      assert Custode.Routine.get(sleeper.id).max_turns != "plenty"
    end

    test "remove takes the agent off the roster and returns to the console",
         %{conn: conn, sleeper: sleeper} do
      {view, _html} = open_edit(conn, sleeper.id)

      view |> element("button[phx-click=edit_remove]") |> render_click()

      assert_patch(view, "/console")
      assert Custode.Routine.get(sleeper.id) == nil
      assert render(view) =~ "its notebook and workspace are kept"
    end
  end

  describe "adding an agent" do
    setup do
      roster = Path.join(System.tmp_dir!(), uid("console-new-roster") <> ".toml")
      System.put_env("CUSTODE_CONFIG", roster)
      previous = Application.get_env(:custode, :routines)

      on_exit(fn ->
        System.delete_env("CUSTODE_CONFIG")
        File.rm(roster)
        Application.put_env(:custode, :routines, previous)
      end)

      %{roster: roster}
    end

    test "Ask setup opens the existing caretaker preview without creating a routine", %{
      conn: conn,
      roster: roster
    } do
      put_env!(:routines, [])
      {:ok, view, _html} = live(conn, "/console?new=caretaker")
      assert has_element?(view, "#new-routine")
      assert has_element?(view, ~s(#new-routine option[value="caretaker"][selected]))
      assert Custode.Routine.all() == []
      refute File.exists?(roster)
    end

    test "Ask setup does not open a second caretaker form when one already exists", %{conn: conn} do
      put_env!(:routines, [
        %{
          id: uid("manager"),
          role: :caretaker,
          cron: "@daily",
          prompt: "coordinate",
          workspace: tmp_workspace!()
        }
      ])

      {:ok, view, _html} = live(conn, "/console?new=caretaker")
      refute has_element?(view, "#new-routine")
      refute has_element?(view, "#caretaker-setup")
    end

    test "the form previews the TOML as you type, creates, and opens the new agent",
         %{conn: conn, roster: roster} do
      id = uid("newcomer")
      {:ok, view, _html} = live(conn, "/console")

      html = view |> element("button[phx-click=new_open]") |> render_click()
      assert html =~ "New agent"

      html =
        view
        |> form("#new-routine", %{
          "routine" => %{"id" => id, "cadence" => "daily", "prompt" => "sweep"}
        })
        |> render_change()

      assert html =~ "appended to the roster"
      assert html =~ "id = &quot;#{id}&quot;"

      view
      |> form("#new-routine", %{
        "routine" => %{"id" => id, "cadence" => "daily", "prompt" => "sweep"}
      })
      |> render_submit()

      assert_patch(view, "/console/#{id}")
      assert File.read!(roster) =~ ~s(id = "#{id}")
      assert %{cron: "@daily"} = Custode.Routine.get(id)
      assert render(view) =~ "live now, scheduled at its next cron minute"
    end

    test "a form with no id says so and creates nothing", %{conn: conn, roster: roster} do
      {:ok, view, _html} = live(conn, "/console")
      view |> element("button[phx-click=new_open]") |> render_click()

      html =
        view
        |> form("#new-routine", %{"routine" => %{"id" => "", "cadence" => "daily"}})
        |> render_change()

      assert html =~ "id is required"
      refute File.exists?(roster)
    end

    test "an empty fleet creates a real caretaker from the recommended choice",
         %{conn: conn} do
      put_env!(:routines, [])
      {:ok, view, _html} = live(conn, "/console")

      view
      |> element(~s(button[phx-click=new_kind][phx-value-kind="caretaker"]))
      |> render_click()

      assert has_element?(view, ~s(#new-routine option[value="caretaker"][selected]))
      view |> form("#new-routine") |> render_submit()

      assert %{role: :caretaker, mcp: true, tags: tags} = Custode.Routine.get("custode")
      assert :meta in tags
      assert_patch(view, "/console/custode")
    end

    test "the normal setup flow offers a provider-aware specialist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      view |> element("button[phx-click=new_open]") |> render_click()
      view |> element("button[phx-click=new_choose]") |> render_click()

      html =
        view
        |> element(~s(button[phx-click=new_kind][phx-value-kind="specialist"]))
        |> render_click()

      assert html =~ "resolved agent"
      assert has_element?(view, ~s(#new-routine option[value="specialist"][selected]))
    end
  end

  describe "an image on a message (#180)" do
    # a 1x1 png, small enough to live inline
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
         )

    test "a chosen image shows as a chip, can be removed, and rides the message as a path",
         %{conn: conn, sleeper: sleeper} do
      {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

      upload = fn name ->
        view
        |> file_input("form[phx-submit=message]", :image, [
          %{name: name, content: @png, type: "image/png"}
        ])
        |> render_upload(name)
      end

      upload.("mistake.png")
      assert render(view) =~ "mistake.png"
      view |> element("button[phx-click=drop_image]") |> render_click()
      refute render(view) =~ "mistake.png"

      upload.("screenshot.png")
      view |> form("form[phx-submit=message]", %{"text" => "what is this"}) |> render_submit()

      # the sleeper is offline, so the message starts a turn: the path has to
      # ride that delivery too, not only a cast to a running agent
      import Ecto.Query, only: [from: 2]

      [turn] =
        Custode.Repo.all(
          from(j in Oban.Job,
            where: j.worker == "ObanClaude.Agent.Job",
            where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^sleeper.id
          )
        )

      assert turn.args["prompt"] =~ "what is this"
      [_, path] = Regex.run(~r/attached image: (\S+)/, turn.args["prompt"])
      assert Path.dirname(path) == Path.join(Path.expand(sleeper.workspace), "uploads")
      assert File.read!(path) == @png
    end
  end

  describe "plan usage in the header (#458)" do
    setup do
      Custode.Availability.forget(:all)
      on_exit(fn -> Custode.Availability.forget(:all) end)
      :ok
    end

    test "nothing observed draws nothing: unknown is not zero percent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      header = view |> element("#console-controls") |> render()

      refute header =~ "Claude plan usage"
      refute header =~ "5h"
      refute header =~ "7d"
      refute header =~ "%"
    end

    test "an observation labels Claude even for a Codex subject and refreshes its windows", %{
      conn: conn
    } do
      routine = routine_fixture!(tmp_workspace!(), %{provider: :codex})
      {:ok, view, _html} = live(conn, "/console/#{routine.id}")

      {:ok, _snapshot} =
        ClaudeUsage.observe(%{
          "rate_limit_info" => %{
            "status" => "allowed",
            "rateLimitType" => "five_hour",
            "unifiedWindows" => %{
              "five_hour" => %{"utilization" => 0.15, "resetsAt" => 1_789_892_400},
              "seven_day" => %{"utilization" => 0.87, "resetsAt" => 1_790_218_800}
            }
          }
        })

      send(view.pid, {:usage_changed, "claude"})
      html = render(view)

      assert has_element?(view, "#console-controls", "Claude plan usage")
      assert html =~ "5h 15%"
      assert html =~ "7d 87%"
      # past the warn threshold reads as a warning
      assert html =~ ~r/text-warning[^>]*>\s*7d 87%/
    end

    test "a stale rejection whose reset is ahead says what holds it (#525)", %{conn: conn} do
      now = DateTime.utc_now()

      Custode.Availability.put(%Custode.Availability.Snapshot{
        provider: "claude",
        source: "test",
        observed_at: DateTime.add(now, -2400, :second),
        buckets: [
          %Custode.Availability.Bucket{
            id: "five_hour",
            status: :rejected,
            utilization: 1.0,
            resets_at: DateTime.add(now, 1200, :second)
          }
        ]
      })

      {:ok, view, _html} = live(conn, "/console")
      header = view |> element("#console-controls") |> render()

      assert header =~ "held until"
      assert header =~ "(from a reading 40m old)"
      refute header =~ ">stale<"
      refute header =~ "opacity-50"
    end
  end

  test "the tabs switch the subject pane", %{conn: conn, sleeper: sleeper} do
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    html = view |> element("button[phx-value-tab=notebook]") |> render_click()
    assert html =~ "journal"
    assert html =~ "nothing queued"

    html = view |> element("button[phx-value-tab=work]") |> render_click()
    assert html =~ "not tied to a repository"
  end
end
