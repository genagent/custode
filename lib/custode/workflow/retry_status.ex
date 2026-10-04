defmodule Custode.Workflow.RetryStatus do
  @moduledoc "Read-only replay preconditions; current workers do not prove safe effects or settlement."
  import Ecto.Query, only: [from: 2]
  alias Custode.Operator.Authority
  alias Custode.Repo
  alias Custode.Workflow.{Catalog, Definition, Results, Run}

  def read(actor, id) when is_binary(id) and id != "" do
    with :ok <- Authority.fleet_control(actor), %{} = run <- Run.get(id) do
      definition =
        case Catalog.fetch(run.workflow) do
          {:ok, definition} -> Definition.snapshot(definition)
          :error -> nil
        end

      jobs =
        Repo.all(
          from(job in Oban.Job,
            where: fragment("json_extract(?, '$.workflow_run')", job.meta) == ^id,
            order_by: [asc: job.id],
            limit: 101,
            select: %{id: job.id, state: job.state, meta: job.meta}
          )
        )

      {:ok,
       explain(run, definition, jobs)
       |> Map.put(:successful_result_count, length(Results.for_run(id)))}
    else
      nil -> {:error, :unknown_run}
      error -> error
    end
  end

  def read(_actor, _id), do: {:error, :invalid_run_id}

  @doc false
  def explain(run, definition, jobs) do
    compatible =
      is_map(run.definition_snapshot) and is_map(definition) and
        is_binary(run.definition_snapshot["fingerprint"]) and
        run.definition_snapshot["fingerprint"] == definition["fingerprint"]

    bound_failure = failure_bound?(run, jobs)

    active =
      Enum.filter(jobs, &(&1.state in ~w(available scheduled executing retryable suspended)))

    reasons =
      [
        reason(
          run.status != "failed",
          "run_not_failed",
          "Only a failed stage could be retried. Budget resume is a separate action."
        ),
        reason(
          not compatible,
          "definition_unavailable_or_changed",
          "The current definition must match the definition captured at launch."
        ),
        reason(
          not bound_failure,
          "failure_execution_unbound",
          "The failed stage, generation and exact job have no verified matching record."
        ),
        reason(
          active != [],
          "unsettled_job_states",
          "Some workflow jobs remain live or queued. Cancellation is not physical settlement."
        ),
        reason(
          length(jobs) > 100,
          "job_inventory_truncated",
          "More than 100 jobs exist; the bounded inventory cannot establish replay readiness."
        ),
        %{
          code: "worker_effects_unproven",
          message:
            "Named write tools are disabled, but the worker does not mechanically confine Bash or MCP effects."
        },
        %{
          code: "physical_settlement_unproven",
          message:
            "Terminal Oban state does not prove the native process and its descendants settled."
        }
      ]
      |> Enum.reject(&is_nil/1)

    %{
      schema_version: "custode.workflow_retry_status.v1",
      run_id: run.run_id,
      admission: "unavailable",
      retry_offered: false,
      definition_compatible: compatible,
      failure_bound: bound_failure,
      reasons: reasons,
      consistency: "independent_read_observations_not_atomic_admission",
      job_inventory_truncated: length(jobs) > 100,
      jobs: Enum.map(Enum.take(jobs, 100), &Map.take(&1, [:id, :state])),
      worker_contract: %{
        basis: "current_NodeJob_configuration_not_observed_historical_launch",
        named_write_tools_disabled: true,
        shell_effects: "not_mechanically_confined",
        mcp_effects: "not_mechanically_confined",
        settlement_receipt: "unavailable"
      },
      cumulative_budget: %{budget_usd: run.budget_usd, replay_reservation: "unavailable"},
      operating_effect: "read_only_no_enqueue_no_cancel_no_resume"
    }
  end

  @failure_fields ~w(stage node_name args_hash execution_generation)

  defp failure_bound?(%{failure_identity: identity} = run, jobs) when is_map(identity) do
    valid_failure?(identity) and
      identity["execution_generation"] == run.execution_generation and
      identity["stage"] == run.stage and
      Enum.any?(jobs, fn job ->
        job.id == identity["callback_job_id"] and
          Map.take(job.meta, @failure_fields) == Map.take(identity, @failure_fields)
      end)
  end

  defp failure_bound?(_run, _jobs), do: false

  defp valid_failure?(identity) do
    Enum.all?(@failure_fields, fn key ->
      is_binary(identity[key]) and identity[key] != ""
    end) and is_integer(identity["callback_job_id"]) and identity["callback_job_id"] > 0
  end

  defp reason(true, code, message), do: %{code: code, message: message}
  defp reason(false, _code, _message), do: nil
end
