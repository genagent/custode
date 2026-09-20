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

    html = view |> element("button[phx-value-id='#{proposal.id}'].btn-success") |> render_click()

    assert html =~ "running"
    # every stage of the DEFINITION, including the ones not reached yet
    assert html =~ "mine"
    assert html =~ "merge"
    assert html =~ "check"
    assert html =~ "per item"
    refute html =~ "launch gate"

    assert [run] = Run.list()
    assert run.budget_usd == 4.0
  end

  test "rejecting the gate leaves no run", %{conn: conn} do
    workflow = register(uid("toy"))
    {:ok, proposal} = Launch.propose(workflow.name, "owner/repo")

    {:ok, view, _html} = live(conn, "/workflows")
    html = view |> element("button[phx-value-id='#{proposal.id}'].btn-ghost") |> render_click()

    assert Run.list() == []
    refute html =~ "badge-warning badge-sm"
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
    assert html =~ "raise the rail and resume"

    resumed = view |> element("button[phx-click='resume_run']") |> render_click()
    assert resumed =~ "running"
    # the rail was RAISED, not removed -- resuming onto the same ceiling would
    # park the run again immediately
    assert Run.get(run.run_id).budget_usd == 2.0
  end

  test "with nothing to show the page says a run starts at a gate", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workflows")
    assert html =~ "a run starts at a launch gate"
  end
end
