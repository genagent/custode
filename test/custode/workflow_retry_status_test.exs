defmodule Custode.WorkflowRetryStatusTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.CLI.Client, as: CLIClient
  alias Custode.MCP.CallContext
  alias Custode.MCP.Identity
  alias Custode.MCP.WorkflowRetryTools.Read
  alias Custode.Repo
  alias Custode.Workflow
  alias Custode.Workflow.{Node, Results, RetryStatus, Run, Runner, Stage}

  alias Snodo.Client

  @actor %{kind: :operator, id: "retry-status-test"}

  setup do
    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))
    on_exit(fn -> Application.delete_env(:custode, :extra_workflows) end)
    :ok
  end

  test "failure inventory preserves accepted siblings and does not change execution" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    [saved, failed, active] = jobs(run.run_id)

    Runner.node_finished(saved.meta, %ClaudeWrapper.Result{
      extra: %{"structured_output" => %{"saved" => true}}
    })

    active |> Ecto.Changeset.change(state: "executing") |> Repo.update!()
    Runner.node_failed(Map.put(failed.meta, "callback_job_id", failed.id), :fixture_failure)
    before = observations(run.run_id)

    assert {:ok, status} = RetryStatus.read(@actor, run.run_id)
    assert status.definition_compatible
    assert status.failure_bound
    assert status.successful_result_count == 1
    assert status.admission == "unavailable"
    refute status.retry_offered
    assert "unsettled_job_states" in codes(status)
    assert "worker_effects_unproven" in codes(status)
    assert "physical_settlement_unproven" in codes(status)
    assert observations(run.run_id) == before
    # These are persisted callback fixtures, not native settlement evidence.
  end

  test "even terminal Oban rows cannot prove physical settlement or replay safety" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    [failed | _] = jobs(run.run_id)
    Runner.node_failed(Map.put(failed.meta, "callback_job_id", failed.id), :fixture_failure)

    Enum.each(jobs(run.run_id), fn job ->
      job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    end)

    assert {:ok, status} = RetryStatus.read(@actor, run.run_id)
    assert status.failure_bound
    refute "unsettled_job_states" in codes(status)
    refute status.retry_offered
    assert "physical_settlement_unproven" in codes(status)
    assert status.worker_contract.shell_effects == "not_mechanically_confined"
  end

  test "definition replacement and legacy unbound failures stay explicit" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    Run.fail(run.run_id, "legacy failure")
    changed = %{workflow | model: "a-different-model"}
    Application.put_env(:custode, :extra_workflows, %{workflow.name => changed})
    assert {:ok, status} = RetryStatus.read(@actor, run.run_id)
    refute status.definition_compatible
    refute status.failure_bound
    assert "definition_unavailable_or_changed" in codes(status)
    assert "failure_execution_unbound" in codes(status)
    Application.delete_env(:custode, :extra_workflows)
    assert {:ok, missing} = RetryStatus.read(@actor, run.run_id)
    refute missing.definition_compatible
  end

  test "running and budget-paused runs are not stage retries" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    assert {:ok, running} = RetryStatus.read(@actor, run.run_id)
    assert "run_not_failed" in codes(running)
    Run.budget_pause(run.run_id, "budget")
    assert {:ok, paused} = RetryStatus.read(@actor, run.run_id)
    assert "run_not_failed" in codes(paused)
    assert Run.get(run.run_id).status == "budget_paused"
  end

  test "authority is checked before exposing a run and MCP uses verified identity" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")

    for actor <- [
          nil,
          %{},
          %{kind: :routine, id: uid("ordinary")},
          %{kind: :sub_agent, id: uid("helper")}
        ] do
      assert {:error, _} = RetryStatus.read(actor, run.run_id)
      assert {:error, _} = RetryStatus.read(actor, "unknown")
    end

    assert {:error, :unknown_run} = RetryStatus.read(@actor, "unknown")
    assert {:error, :invalid_run_id} = RetryStatus.read(@actor, "")
    assert Read.execute(%{run_id: run.run_id}, %CallContext{}) |> tool_error() =~ "verified"
    frame = %CallContext{assigns: %{custode_identity: @actor}}

    assert Read.execute(%{run_id: run.run_id}, frame)
           |> tool_json()
           |> Map.fetch!("retry_offered") == false
  end

  test "CLI and both HTTP protocol revisions return the shared read without new jobs" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    Run.fail(run.run_id, "legacy fixture failure")
    before = observations(run.run_id)

    assert {:ok, %{"retry_offered" => false, "run_id" => id}} =
             CLIClient.call("workflow_retry_status", %{run_id: run.run_id})

    assert id == run.run_id

    {:ok, token} = Identity.operator_token()

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               Client.call_tool(client, "workflow_retry_status", %{"run_id" => run.run_id})

      assert Jason.decode!(text)["retry_offered"] == false

      assert {:ok, %{"isError" => false, "content" => [%{"text" => ignored}]}} =
               Client.call_tool(client, "workflow_retry_status", %{
                 "run_id" => run.run_id,
                 "actor" => "forged"
               })

      assert Jason.decode!(ignored)["run_id"] == run.run_id
      assert :ok = Client.close(client)
    end

    assert observations(run.run_id) == before
  end

  test "truncated inventories cannot establish replay readiness" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")
    jobs = Enum.map(1..101, &%{id: &1, state: "completed", meta: %{}})
    status = RetryStatus.explain(run, run.definition_snapshot, jobs)
    assert status.job_inventory_truncated
    assert length(status.jobs) == 100
    assert "job_inventory_truncated" in codes(status)
    refute status.retry_offered
  end

  test "missing failure fields never match nil job metadata" do
    workflow = register!()
    {:ok, run} = Runner.launch(workflow.name, "owner/repo")

    run = %{
      run
      | failure_identity: %{
          "callback_job_id" => 1,
          "stage" => run.stage,
          "execution_generation" => run.execution_generation
        }
    }

    job = %{
      id: 1,
      state: "completed",
      meta: %{"stage" => run.stage, "execution_generation" => run.execution_generation}
    }

    refute RetryStatus.explain(run, run.definition_snapshot, [job]).failure_bound
  end

  defp codes(status), do: Enum.map(status.reasons, & &1.code)
  defp observations(id), do: {Run.get(id), Results.for_run(id), jobs(id)}

  defp jobs(id),
    do:
      Repo.all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^id,
          order_by: [asc: j.id]
        )
      )

  defp register! do
    workflow =
      Workflow.new!(uid("retry-audit"), [
        %Stage{
          name: :review,
          nodes:
            Enum.map(
              [:saved, :failed, :active],
              &%Node{name: &1, prompt: "read <%= @repo %>", schema: %{"type" => "object"}}
            )
        }
      ])

    Application.put_env(:custode, :extra_workflows, %{workflow.name => workflow})
    workflow
  end
end
