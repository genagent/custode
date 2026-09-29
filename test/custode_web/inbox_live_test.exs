defmodule CustodeWeb.InboxLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks
  alias Custode.Sensors.CiStatus
  alias Custode.Sensors.CiStatus.Infrastructure
  alias Custode.Workflow
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run

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
    # launch proposals and parked runs are inbox rows too now (#447)
    Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
    Custode.Repo.query!("DELETE FROM workflow_node_results")
    Custode.Repo.query!("DELETE FROM workflow_runs")
    Custode.Repo.query!("DELETE FROM memories WHERE key = 'ci_infrastructure'")

    on_exit(fn ->
      Custode.Repo.query!("DELETE FROM asks")
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
      Custode.Repo.query!("DELETE FROM workflow_runs")
      Custode.Repo.query!("DELETE FROM oban_jobs WHERE worker = 'Custode.Workflow.NodeJob'")
      Custode.Repo.query!("DELETE FROM memories WHERE key = 'ci_infrastructure'")
      Application.delete_env(:custode, :extra_workflows)
    end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine, workspace: workspace}
  end

  test "an empty inbox says so rather than showing a bare page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ "Nothing needs you"
    # and it points at where the fleet's state actually is
    assert html =~ "console"
  end

  test "a repository condition links to the encoded console subject",
       %{conn: conn, routine: routine} do
    repo = "acme/widgets"

    put_env!(:sensors, [
      %{
        id: "ci-inbox",
        cron: "@hourly",
        module: CiStatus,
        notify: routine.id,
        args: %{repo: repo}
      }
    ])

    :ok =
      Infrastructure.replace(
        %{"sensor_id" => "ci-inbox", "notify" => routine.id, "repo" => repo},
        [%{kind: :pr, number: 9, head_sha: "head-9"}],
        5
      )

    {:ok, view, _html} = live(conn, "/inbox")

    assert has_element?(view, ~s(a[href="/console/acme%2Fwidgets"]))
  end

  test "an offline approval offers and performs truthful recovery", %{
    conn: conn,
    routine: routine
  } do
    gate =
      Custode.Repo.insert!(%Custode.Gates.Gate{
        agent_id: routine.id,
        kind: "approval",
        action_id: "act_departed",
        detail: "publish the release"
      })

    {:ok, view, html} = live(conn, "/inbox")

    assert html =~ "approval needs recovery"
    assert html =~ "Requeue"
    refute html =~ ">Approve<"

    html =
      view
      |> element(~s(button[phx-click=recover_gate][phx-value-action="#{gate.action_id}"]))
      |> render_click()

    assert html =~ "approval requeued for agent re-evaluation"
    assert Custode.Repo.get!(Custode.Gates.Gate, gate.id).status == "requeued"
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

  test "dismissing from an open reply closes only that ask and delivers nothing",
       %{conn: conn, routine: routine, workspace: workspace} do
    {:ok, first} = Asks.ask(routine.id, "obsolete question?")
    {:ok, second} = Asks.ask(routine.id, "still relevant?")
    inbox = Path.wildcard(Path.join([workspace, "inbox", "*"]))
    {:ok, view, _html} = live(conn, "/inbox")

    view
    |> element(~s(button[phx-click=reply_open][phx-value-ask="#{first.id}"]))
    |> render_click()

    assert has_element?(view, "form[phx-submit=reply_send]")

    html =
      view
      |> element(~s(button[phx-click=dismiss_ask][phx-value-ask="#{first.id}"]))
      |> render_click()

    assert %{status: "dismissed", dismissal_reason: nil, answer: nil} = Asks.get(first.id)
    assert Asks.get(second.id).status == "open"
    assert Path.wildcard(Path.join([workspace, "inbox", "*"])) == inbox
    refute has_element?(view, "form[phx-submit=reply_send]")
    refute html =~ "obsolete question?"
    assert html =~ "still relevant?"
    assert has_element?(view, ~s(button[phx-click=dismiss_ask][phx-value-ask="#{second.id}"]))
  end

  test "a stale dismissal keeps its displayed id and cannot dismiss the successor",
       %{conn: conn, routine: routine} do
    {:ok, first} = Asks.ask(routine.id, "old question?")
    {:ok, second} = Asks.ask(routine.id, "next question?")
    {:ok, view, _html} = live(conn, "/inbox")

    assert has_element?(view, ~s(button[phx-click=dismiss_ask][phx-value-ask="#{first.id}"]))
    {:ok, _dismissed} = Asks.dismiss(first.id)

    eventually(fn ->
      assert has_element?(view, ~s(button[phx-click=dismiss_ask][phx-value-ask="#{second.id}"]))
    end)

    for _repeat <- 1..2 do
      html = render_click(view, "dismiss_ask", %{"ask" => to_string(first.id)})
      assert html =~ "already dismissed"
      assert Asks.get(second.id).status == "open"
      assert has_element?(view, ~s(button[phx-click=dismiss_ask][phx-value-ask="#{second.id}"]))
    end
  end

  test "the hard bottom names what it left out", %{conn: conn, routine: routine} do
    {:ok, _ask} = Asks.ask(routine.id, "anything")

    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ "That&#39;s everything." or html =~ "That's everything."
    # the omission is stated, not silent -- that is what makes it trustworthy
    assert html =~ "Sweeps, sensor pings and journal entries"
    assert html =~ "on their agents"
  end

  describe "the workflow queues (#447)" do
    defp node_fixture(name) do
      %Workflow.Node{name: name, prompt: "do <%= @repo %>", schema: %{}}
    end

    defp register_workflow! do
      workflow =
        Workflow.new!(uid("inbox-wf"), [
          %Workflow.Stage{name: :mine, nodes: [node_fixture(:spec)]},
          %Workflow.Stage{name: :merge, nodes: [node_fixture(:merge)]}
        ])

      Application.put_env(:custode, :extra_workflows, %{workflow.name => workflow})
      workflow
    end

    # A run parked on its rail, built from the two stores the gatherer reads:
    # the run row and the feed entry that dates the pause.
    defp parked_run!(workflow, budget_usd) do
      run = Run.start(uid("inbox-run"), workflow.name, "owner/repo", :mine, %{}, budget_usd)
      Run.budget_pause(run.run_id, "run budget rail hit: $1.20 of $1.00", ["merge"])

      Custode.Feed.record(%{
        event: "workflow_budget_paused",
        agent: nil,
        run: run.run_id,
        workflow: workflow.name,
        repo: "owner/repo",
        summary: "parked"
      })

      run
    end

    test "a launch proposal is a row with the estimate, approve and reject", %{conn: conn} do
      workflow = register_workflow!()
      {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo", why: "the board is dry")

      {:ok, view, html} = live(conn, "/inbox")

      refute html =~ "Nothing needs you"
      assert html =~ "#{workflow.name} on owner/repo"
      assert html =~ "launch gate"
      assert html =~ "wants your approval to launch"
      assert html =~ "the board is dry"
      assert has_element?(view, "button[phx-click=approve_launch]", "Approve")
      assert has_element?(view, "button[phx-click=reject_launch]", "Reject")
      # the subject and the navigation op lead to the workflows page: there is
      # no agent called "<workflow> on <repo>"
      assert has_element?(view, ~s(a[href="/workflows"]), "Open workflows")
      refute html =~ ~s(href="/console/#{workflow.name})
    end

    test "approving from the inbox launches the run and clears the row", %{conn: conn} do
      workflow = register_workflow!()
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 3.5)

      {:ok, view, _html} = live(conn, "/inbox")
      html = view |> element("button[phx-click=approve_launch]") |> render_click()

      assert [run] = Run.list()
      assert run.workflow == workflow.name
      assert run.budget_usd == 3.5
      assert Launch.pending() == []
      assert html =~ "launched #{workflow.name}"
      refute html =~ "wants your approval to launch"
      refute Enum.any?(Launch.pending(), &(&1["proposal"] == proposal.id))
    end

    test "rejecting from the inbox closes the gate and starts nothing", %{conn: conn} do
      workflow = register_workflow!()
      {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo")

      {:ok, view, _html} = live(conn, "/inbox")
      html = view |> element("button[phx-click=reject_launch]") |> render_click()

      assert Run.list() == []
      assert Launch.pending() == []
      assert Launch.recently_rejected?(workflow.name, "owner/repo")
      assert html =~ "Nothing needs you"
    end

    test "a run parked on its rail is a row that says what it did not run", %{conn: conn} do
      run = parked_run!(register_workflow!(), 1.0)

      {:ok, view, html} = live(conn, "/inbox")

      assert html =~ "run rail"
      assert html =~ "run #{run.run_id} is parked on its budget rail"
      assert html =~ "paused before merge"
      assert has_element?(view, "button[phx-click=resume_run]", "Raise the rail and resume")
    end

    test "raising the rail from the inbox doubles it, resumes the run and clears the row",
         %{conn: conn} do
      run = parked_run!(register_workflow!(), 1.0)

      {:ok, view, _html} = live(conn, "/inbox")
      html = view |> element("button[phx-click=resume_run]") |> render_click()

      resumed = Run.get(run.run_id)
      assert resumed.status == "running"
      assert resumed.budget_usd == 2.0
      assert html =~ "resumed on a raised rail"
      refute html =~ "is parked on its budget rail"
    end

    test "the header chip counts a launch proposal on every page", %{conn: conn} do
      workflow = register_workflow!()
      {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo")

      {:ok, _view, html} = live(conn, "/metrics")

      assert html =~ "#{workflow.name} on owner/repo awaits your launch approval"
    end
  end

  test "/feed keeps its route after leaving the top nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/inbox")
    refute html =~ ~s(href="/feed")

    assert {:ok, _view, _html} = live(conn, "/feed")
  end
end
