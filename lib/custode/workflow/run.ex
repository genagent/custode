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
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @statuses ~w(running complete failed)

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
      field(:started_at, :utc_datetime_usec)
      field(:finished_at, :utc_datetime_usec)
    end
  end

  @doc """
  Open a run. `run_id` is the caller's (the runner mints one); `stage` is the
  first stage's name. `context` is the extra render bindings the launch
  supplied, stored so a resume renders the same prompts it started with.
  """
  def start(run_id, workflow, repo, stage, context \\ %{}) do
    Repo.insert!(%Row{
      run_id: to_string(run_id),
      workflow: to_string(workflow),
      repo: to_string(repo),
      status: "running",
      stage: to_string(stage),
      context: Jason.encode!(context),
      notes: Jason.encode!([]),
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
      started_at: row.started_at,
      finished_at: row.finished_at
    }
  end
end
