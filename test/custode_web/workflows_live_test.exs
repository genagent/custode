defmodule CustodeWeb.WorkflowsLiveTest do
  # The workflows page (#271 slice 2): the launch gates waiting on a decision
  # and the runs those decisions produced, as stage checklists.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Repo
  alias Custode.Workflow
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Node
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner
  alias Custode.Workflow.Stage

  @endpoint CustodeWeb.Endpoint

  setup do
    feed = Path.join(System.tmp_dir!(), uid("wf-lv-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))

    Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")

    on_exit(fn ->
      File.rm(feed)
      Application.delete_env(:custode, :extra_workflows)
      # a standing proposal or a parked run is a needs-you signal now (#447),
      # so leaving one behind changes what every later attention read sees
      Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
      Repo.delete_all(Results.Result)
      Repo.delete_all(Run.Row)
    end)

    %{conn: build_conn()}
  end

  defp node_fixture(name), do: %Node{name: name, prompt: "do <%= @repo %>", schema: %{}}

  defp register(name) do
    workflow =
      Workflow.new!(name, [
        %Stage{name: :mine, nodes: [node_fixture(:spec), node_fixture(:code)]},
        %Stage{name: :merge, nodes: [node_fixture(:merge)]},
        %Stage{name: :check, per_item: true, nodes: [node_fixture(:check)]}
      ])

    Application.put_env(:custode, :extra_workflows, %{workflow.name => workflow})
    workflow
  end

  defp finish(run_id, node_name, structured \\ %{"ok" => true}) do
    job =
      from(j in Oban.Job,
        where: j.worker == "Custode.Workflow.NodeJob",
        where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run_id
      )
      |> Repo.all()
      |> Enum.find(&(&1.meta["node_name"] == node_name))

    Runner.node_finished(
      job.meta,
      %ClaudeWrapper.Result{result: "ran", extra: %{"structured_output" => structured}}
    )
  end

  test "a standing gate shows the estimate and says what it cannot know", %{conn: conn} do
    workflow = register(uid("toy"))
    {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo", why: "the board is dry")

    {:ok, _view, html} = live(conn, "/workflows")

    assert html =~ "launch gate"
    assert html =~ workflow.name
    assert html =~ "the board is dry"
    # the floor, flagged as a floor, because a per_item stage has no knowable
    # node count before its merge runs
    assert html =~ "fans out"
    assert html =~ "not knowable before the run"
  end

  test "approving the gate starts the run and the page shows its checklist", %{conn: conn} do
    workflow = register(uid("toy"))
    {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 4.0)

    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> element("button[phx-click=approve_launch][phx-value-id='#{proposal.id}']")
      |> render_click()

    assert html =~ "running"
    # every stage of the DEFINITION, including the ones not reached yet
    assert html =~ "mine"
    assert html =~ "merge"
    assert html =~ "check"
    assert html =~ "per item"
    assert has_element?(view, "[data-stage-state='running'] .sr-only", "Running")
    assert has_element?(view, "[data-stage-state='pending'] .sr-only", "Pending")
    refute html =~ "launch gate"

    assert [run] = Run.list()
    assert run.budget_usd == 4.0
  end

  test "rejecting the gate leaves no run", %{conn: conn} do
    workflow = register(uid("toy"))
    {:ok, proposal} = Launch.propose(workflow.name, "owner/repo")

    {:ok, view, _html} = live(conn, "/workflows")

    view
    |> element("button[phx-click=reject_launch][phx-value-id='#{proposal.id}']")
    |> render_click()

    assert Run.list() == []
    refute has_element?(view, "button[phx-click=approve_launch][phx-value-id='#{proposal.id}']")
    assert Launch.pending() == []
  end

  test "a parked run shows what it did not run and offers the rail raise", %{conn: conn} do
    workflow = register(uid("toy"))
    {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
    {:ok, run} = Launch.approve(proposal.id)

    finish(run.run_id, "spec")
    Custode.SpendLedger.record(Run.spend_agent_id(run.run_id), 1.5)
    finish(run.run_id, "code")

    {:ok, view, html} = live(conn, "/workflows")

    assert html =~ "budget_paused"
    assert html =~ "what it did not do"
    assert html =~ "Raise the rail and resume"
    assert has_element?(view, "[data-stage-state='done'] .sr-only", "Done")

    resumed = view |> element("button[phx-click='resume_run']") |> render_click()
    assert resumed =~ "running"
    # the rail was RAISED, not removed -- resuming onto the same ceiling would
    # park the run again immediately
    assert Run.get(run.run_id).budget_usd == 2.0
  end

  test "a failed stage contains its full escaped error and keeps successful siblings", %{
    conn: conn
  } do
    workflow = register(uid("failed-display"))
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    finish(run.run_id, "spec")

    error =
      "<script>alert('failure')</script> " <> String.duplicate("long-error-without-spaces", 40)

    Run.fail(run.run_id, error)

    {:ok, view, html} = live(conn, "/workflows")
    card = "[data-workflow-run='#{run.run_id}']"
    stage = card <> " [data-workflow-stage='mine'][data-stage-state='failed']"

    assert has_element?(view, stage, "Failed")
    assert has_element?(view, stage, "spec")
    assert has_element?(view, stage <> " [data-foldable-full]", error)
    assert has_element?(view, stage <> " details:not([open]) summary", "Show more")

    assert has_element?(
             view,
             card <> " [data-workflow-stage='merge'][data-stage-state='not_run']",
             "Not run"
           )

    assert has_element?(
             view,
             card <> " [data-workflow-stage='check'][data-stage-state='not_run']",
             "Not run"
           )

    refute has_element?(view, card <> " script")
    refute has_element?(view, card <> " button[phx-click='resume_run']")

    assert has_element?(view, card, "cannot yet prove earlier agents stopped")

    assert has_element?(
             view,
             card <> " details[data-workflow-retry-status]:not([open])",
             "Why retry is unavailable"
           )

    assert has_element?(
             view,
             card <> " details[data-workflow-retry-status]",
             "does not mechanically confine Bash or MCP effects"
           )

    assert html =~ "without bound validation"
    assert html =~ "This does not make a retry safe."
    refute html =~ "retry_run"
    assert Run.get(run.run_id).error == error
  end

  test "unknown attribution shows saved error and successes without completed stages", %{
    conn: conn
  } do
    for cursor <- [nil, "merge_missing"] do
      workflow = register(uid("unknown-display"))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo")
      finish(run.run_id, "spec")
      Run.fail(run.run_id, "node merge failed; do not infer that stage from this text")
      row = Repo.get_by!(Run.Row, run_id: run.run_id)
      row |> Ecto.Changeset.change(stage: cursor) |> Repo.update!()

      {:ok, view, _html} = live(conn, "/workflows")
      card = "[data-workflow-run='#{run.run_id}']"
      fallback = card <> " [data-stage-state='unavailable']"

      assert has_element?(view, fallback, "Recorded stopping stage unavailable")
      assert has_element?(view, fallback, "Recorded successful nodes: spec")
      assert has_element?(view, fallback, "node merge failed")
      refute has_element?(view, card <> " [data-stage-state='done']")
      refute has_element?(view, card <> " [data-stage-state='failed']")
      refute has_element?(view, card <> " button[phx-click='resume_run']")
      GenServer.stop(view.pid)
    end
  end

  test "removed catalog entry shows its saved failure and results", %{conn: conn} do
    workflow = register(uid("removed-display"))
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    finish(run.run_id, "spec")
    Run.fail(run.run_id, "saved failure")
    Application.delete_env(:custode, :extra_workflows)

    Repo.update_all(from(r in Run.Row, where: r.run_id == ^run.run_id),
      set: [definition_snapshot: nil]
    )

    {:ok, view, _html} = live(conn, "/workflows")
    fallback = "[data-workflow-run='#{run.run_id}'] [data-stage-state='unavailable']"

    assert has_element?(view, fallback, "This workflow is no longer in the catalog")
    assert has_element?(view, fallback, "Recorded stage: mine")
    assert has_element?(view, fallback, "Recorded successful nodes: spec")
    assert has_element?(view, fallback, "saved failure")
  end

  test "with nothing to show the page says a run starts at a gate", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workflows")
    assert html =~ "a run starts at a launch gate"
  end
end
