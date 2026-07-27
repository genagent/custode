defmodule Custode.Workflow.Run do
  @moduledoc """
  One workflow run: which catalog entry, against which repo, how far it has
  got (design/005 slice 1b, #271).

  `Custode.Workflow.Results` records what has FINISHED. This records what is
  being run at all. The pair is what makes a run resolvable from nothing but
  its id: the run row names the workflow, so a fresh process can look the
  definition up in the catalog and diff it against the persisted results to
  decide what to enqueue.

  ## notes

  `note/2` appends a line to the run saying what it could NOT do -- a per_item
  stage that expanded to zero items, a node whose result did not honour its
  schema. A run that quietly covers less than it looks like it covered is the
  silent-cap failure the fleet keeps ruling out; a finished run reads back with
  its own gaps attached.

  ## the budget rail (slice 2)

  `budget_usd` is the run's OWN ceiling, separate from the per-node cap and
  from the routines' daily rails. Crossing it moves the run to
  `budget_paused` -- a fourth status, resumable, distinct from `failed`
  because nothing went wrong. Spend is attributed to the synthetic agent id
  `spend_agent_id/1`, which is what the runner already stamps on every node
  job's meta, so the rail is a plain `Custode.SpendLedger` read and there are
  no bespoke counters (the emit-from-birth rule).
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @statuses ~w(running complete failed budget_paused)

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    schema "workflow_runs" do
      field(:run_id, :string)
      field(:workflow, :string)
      field(:repo, :string)
      field(:status, :string)
      field(:stage, :string)
      field(:context, :string)
      field(:notes, :string)
      field(:error, :string)
      field(:budget_usd, :float)
      field(:started_at, :utc_datetime_usec)
      field(:finished_at, :utc_datetime_usec)
    end
  end

  @doc """
  Open a run. `run_id` is the caller's (the runner mints one); `stage` is the
  first stage's name. `context` is the extra render bindings the launch
  supplied, stored so a resume renders the same prompts it started with.
  `budget_usd` is the run's rail, or nil for an unbounded run (iex, tests --
  the launch gate always sets one).
  """
  def start(run_id, workflow, repo, stage, context \\ %{}, budget_usd \\ nil) do
    Repo.insert!(%Row{
      run_id: to_string(run_id),
      workflow: to_string(workflow),
      repo: to_string(repo),
      status: "running",
      stage: to_string(stage),
      context: Jason.encode!(context),
      notes: Jason.encode!([]),
      budget_usd: budget_usd,
      started_at: DateTime.utc_now()
    })
    |> load()
  end

  @doc "A run by id, or nil."
  def get(run_id) do
    Repo.one(from(r in Row, where: r.run_id == ^to_string(run_id))) |> load()
  end

  @doc "Runs, newest first. `status:` filters to one status."
  def list(opts \\ []) do
    query = from(r in Row, order_by: [desc: r.id])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(r in query, where: r.status == ^to_string(status))
      end

    query |> Repo.all() |> Enum.map(&load/1)
  end

  @doc "Move the stage cursor. Only a running run moves."
  def set_stage(run_id, stage) do
    update(run_id, stage: to_string(stage))
  end

  @doc "Mark a run finished. No stage cursor remains -- there is nothing next."
  def complete(run_id) do
    update(run_id, status: "complete", stage: nil, finished_at: DateTime.utc_now())
  end

  @doc """
  Mark a run failed with the reason. The stage cursor stays put: it is the
  record of how far the run got, and a failed run that has forgotten where it
  stopped cannot be read back or (later) resumed.
  """
  def fail(run_id, reason) do
    update(run_id,
      status: "failed",
      error: to_string(reason),
      finished_at: DateTime.utc_now()
    )
  end

  @doc """
  Park a run on its budget rail. The stage cursor and every result stay put,
  and `finished_at` stays nil, because the run is not finished -- it is
  waiting for an operator to raise the rail or let it go.

  `pending` is the node names the rail stopped, recorded as a note: a paused
  run says what it has NOT done rather than reading like a thin one.
  """
  def budget_pause(run_id, reason, pending \\ []) do
    note(run_id, pause_note(reason, pending))
    update(run_id, status: "budget_paused", error: to_string(reason))
  end

  defp pause_note(reason, []), do: "#{reason}; paused with no node outstanding"

  defp pause_note(reason, pending),
    do: "#{reason}; paused before #{Enum.join(pending, ", ")}"

  @doc """
  Return a paused run to `running`, optionally raising its rail. Clears the
  pause reason: a run carrying the message that stopped it after it has been
  let go reads as still stopped.

  Raising the rail is the operator's to decide, so this does not check the
  new value against what has already been spent -- a resume onto an unraised
  rail parks the run again on its next advance, with the same note, which is
  the honest outcome rather than a silent overrun.
  """
  def unpause(run_id, budget_usd \\ :keep) do
    changes = [status: "running", error: nil]
    changes = if budget_usd == :keep, do: changes, else: [{:budget_usd, budget_usd} | changes]
    update(run_id, changes)
  end

  @doc """
  The agent id a run's spend is booked under. The runner already stamps this
  on every node job's meta, so `Custode.SpendLedger` records a run's cost
  without knowing workflows exist.
  """
  def spend_agent_id(run_id), do: "workflow-" <> to_string(run_id)

  @doc "What a run has spent so far, across every node it has run."
  def spent(run_id) do
    Custode.SpendLedger.total(spend_agent_id(run_id), ~U[1970-01-01 00:00:00Z])
  end

  @doc "Append a line to the run's notes -- something it did not do."
  def note(run_id, text) do
    case Repo.one(from(r in Row, where: r.run_id == ^to_string(run_id))) do
      nil ->
        nil

      row ->
        notes = Jason.decode!(row.notes) ++ [to_string(text)]

        row
        |> Ecto.Changeset.change(notes: Jason.encode!(notes))
        |> Repo.update!()
        |> load()
    end
  end

  @doc "The statuses a run row may carry."
  def statuses, do: @statuses

  defp update(run_id, changes) do
    case Repo.one(from(r in Row, where: r.run_id == ^to_string(run_id))) do
      nil ->
        nil

      row ->
        row
        |> Ecto.Changeset.change(Map.new(changes))
        |> Repo.update!()
        |> load()
    end
  end

  defp load(nil), do: nil

  defp load(%Row{} = row) do
    %{
      run_id: row.run_id,
      workflow: row.workflow,
      repo: row.repo,
      status: row.status,
      stage: row.stage,
      context: Jason.decode!(row.context),
      notes: Jason.decode!(row.notes),
      error: row.error,
      budget_usd: row.budget_usd,
      started_at: row.started_at,
      finished_at: row.finished_at
    }
  end
end
