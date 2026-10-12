defmodule Custode.Workflow.BudgetResume do
  @moduledoc "Exact-pause, human-attributed budget admissions with retained retry receipts."

  import Ecto.Query, only: [from: 2]
  alias Custode.{Feed, Repo}
  alias Custode.Workflow.{Run, Runner}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    schema "workflow_budget_resumes" do
      field(:run_id, :string)
      field(:pause_id, :string)
      field(:previous_budget_usd, :float)
      field(:budget_usd, :float)
      field(:actor_id, :string)
      field(:via, :string)
      field(:admitted_at, :utc_datetime_usec)
    end
  end

  @doc "Admit once; receipt status describes admission, never current execution or settlement."
  def resume(run_id, pause_id, actor, via) do
    with :ok <- human(actor),
         :ok <- reference(pause_id),
         {:ok, {row, events}} <- admit(run_id, pause_id, actor.id, via) do
      Enum.each(events, &Runner.publish_launch_event/1)
      Runner.advance_budget_admitted(run_id, pause_id)
      {:ok, receipt(row)}
    end
  end

  defp human(%{kind: :operator, id: id}) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp human(_actor), do: {:error, :human_identity_required}

  defp reference(id) when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 160, do: :ok
  defp reference(_id), do: {:error, :pause_required}

  defp admit(run_id, pause_id, actor_id, via) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_unsupported}
    else
      Repo.transaction(fn -> admit_locked(run_id, pause_id, actor_id, via) end, mode: :immediate)
    end
  rescue
    _error -> {:error, :admission_failed}
  end

  defp admit_locked(run_id, pause_id, actor_id, via) do
    run = Run.get(run_id) || Repo.rollback(:no_such_run)

    case Repo.one(from(r in Row, where: r.run_id == ^run_id and r.pause_id == ^pause_id)) do
      nil -> create_decision(run, pause_id, actor_id, via)
      row -> {row, []}
    end
  end

  defp create_decision(run, pause_id, actor_id, via) do
    if run.status != "budget_paused", do: Repo.rollback(:not_paused)
    if run.budget_pause_id != pause_id, do: Repo.rollback(:stale_pause)
    budget = if is_nil(run.budget_usd), do: nil, else: run.budget_usd * 2

    row =
      Repo.insert!(%Row{
        run_id: run.run_id,
        pause_id: pause_id,
        previous_budget_usd: run.budget_usd,
        budget_usd: budget,
        actor_id: actor_id,
        via: to_string(via),
        admitted_at: DateTime.utc_now()
      })

    Run.admit_budget_resume(run.run_id, pause_id, budget)

    case Feed.record_in_transaction(%{
           event: "workflow_resumed",
           agent: nil,
           run: run.run_id,
           workflow: run.workflow,
           repo: run.repo,
           pause_id: pause_id,
           previous_budget_usd: run.budget_usd,
           budget_usd: budget,
           actor: %{kind: "operator", id: actor_id},
           via: to_string(via),
           summary: "admitted budget resume for #{run.workflow} run #{run.run_id}"
         }) do
      {:ok, event} -> {row, [event]}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp receipt(row) do
    %{
      schema_version: "custode.workflow_budget_resume.v1",
      run_id: row.run_id,
      pause_id: row.pause_id,
      decision: "resumed",
      previous_budget_usd: row.previous_budget_usd,
      budget_usd: row.budget_usd,
      status: "running"
    }
  end
end
