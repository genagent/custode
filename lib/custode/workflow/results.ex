defmodule Custode.Workflow.Results do
  @moduledoc """
  Persisted node results, keyed by `{workflow_run, node_name, args_hash}`
  (design/005, storage doctrine design/002).

  A node result is a RECORD by the doctrine's test: the machine queries it
  back, on every stage barrier and on every restart. So it lives in a table,
  not a file. A long report ARTIFACT a node produces is a message and stays
  a file in the workspace; the row references it, it is not stuffed in here.

  ## What the key buys

  * **Resume after restart** -- the runner enqueues only the nodes with no
    persisted result. Nothing re-runs because the process died.
  * **Edit and re-run only what changed** -- `args_hash` is the hash of the
    node's rendered inputs, so editing one prompt invalidates that node and
    everything downstream of it (their digests change, so their hashes do)
    while untouched nodes keep their results.

  The runner uses `put_once/1`: duplicate callbacks preserve the first accepted
  result and its validation receipt. Legacy administrative `put/1` still upserts;
  replacing a row without its receipt leaves it explicitly unbound. Neither key
  equality nor schema validation alone authorizes a failed-stage replay.

  ## Retention (#39)

  `Custode.Janitor` retires these rows with their run, once that run has
  FINISHED and its `finished_at` is past `janitor: [workflow_runs_days: N]`.
  A run still `running` or `budget_paused` keeps every result however old it
  is -- they are what a resume reads instead of re-running the nodes.

  The report ARTIFACT a row points at goes with the row: `artifacts/1` is
  what the janitor reads first, so the file and the only reference to it
  retire together rather than the file outliving every trace of the run.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Result do
    @moduledoc false
    use Ecto.Schema

    schema "workflow_node_results" do
      field(:workflow_run, :string)
      field(:workflow, :string)
      field(:stage, :string)
      field(:node_name, :string)
      field(:args_hash, :string)
      field(:result, :string)
      field(:artifact, :string)
      field(:attempt_id, :string)
      field(:validation, :map)
      field(:at, :utc_datetime_usec)
    end
  end

  @doc """
  Record one node's result. `attrs` takes `:workflow_run`, `:workflow`,
  `:stage`, `:node_name`, `:args_hash`, the `:result` map, and an optional
  `:artifact` path. Returns the stored map.
  """
  def put(attrs), do: persist(attrs, :replace)

  @doc "Keep the first accepted result for an execution key; duplicate callbacks cannot rewrite it."
  def put_once(attrs), do: persist(attrs, :nothing)

  defp persist(attrs, conflict) do
    row = %Result{
      workflow_run: to_string(attrs.workflow_run),
      workflow: to_string(attrs.workflow),
      stage: to_string(attrs.stage),
      node_name: to_string(attrs.node_name),
      args_hash: attrs.args_hash,
      result: Jason.encode!(Map.get(attrs, :result) || %{}),
      artifact: Map.get(attrs, :artifact),
      attempt_id: Map.get(attrs, :attempt_id),
      validation: Map.get(attrs, :validation),
      at: DateTime.utc_now()
    }

    Repo.insert!(row,
      on_conflict:
        if(conflict == :nothing,
          do: :nothing,
          else: {:replace, [:result, :artifact, :attempt_id, :validation, :stage, :workflow, :at]}
        ),
      conflict_target: [:workflow_run, :node_name, :args_hash]
    )

    fetch(row.workflow_run, row.node_name, row.args_hash)
  end

  @doc """
  Point an existing result at the file its content was written to
  (`Custode.Workflow.Report`). Returns the updated result, or nil when there
  is no such row.

  Separate from `put/1` because the artifact is written AFTER the result is
  stored: the node returns its markdown inside the result, the run completes,
  and only then does anything decide where the file goes. Re-putting the whole
  row to add a path would rewrite a result that has not changed.
  """
  def set_artifact(workflow_run, node_name, args_hash, artifact) do
    case Repo.one(
           from(r in Result,
             where:
               r.workflow_run == ^to_string(workflow_run) and
                 r.node_name == ^to_string(node_name) and
                 r.args_hash == ^args_hash
           )
         ) do
      nil ->
        nil

      row ->
        row
        |> Ecto.Changeset.change(artifact: artifact)
        |> Repo.update!()
        |> load()
    end
  end

  @doc """
  One node's persisted result, or nil. The runner's "has this already run?"
  read: nil means enqueue it.
  """
  def fetch(workflow_run, node_name, args_hash) do
    from(r in Result,
      where:
        r.workflow_run == ^to_string(workflow_run) and
          r.node_name == ^to_string(node_name) and
          r.args_hash == ^args_hash
    )
    |> Repo.one()
    |> load()
  end

  @doc "Every persisted result for a run, oldest first."
  def for_run(workflow_run) do
    from(r in Result,
      where: r.workflow_run == ^to_string(workflow_run),
      order_by: [asc: r.id]
    )
    |> Repo.all()
    |> Enum.map(&load/1)
  end

  @doc "The results of one stage of a run, oldest first."
  def for_stage(workflow_run, stage) do
    from(r in Result,
      where: r.workflow_run == ^to_string(workflow_run) and r.stage == ^to_string(stage),
      order_by: [asc: r.id]
    )
    |> Repo.all()
    |> Enum.map(&load/1)
  end

  @doc """
  The artifact paths a run's results point at, oldest first, without the
  rows that carry them.

  `Custode.Janitor` reads this BEFORE `delete_run/1`: once the rows are gone
  nothing names the files any more, and a report nobody can reach from a run
  is exactly the growth #39 is about. Nodes that produced no artifact
  contribute nothing.
  """
  def artifacts(workflow_run) do
    from(r in Result,
      where: r.workflow_run == ^to_string(workflow_run) and not is_nil(r.artifact),
      order_by: [asc: r.id],
      select: r.artifact
    )
    |> Repo.all()
  end

  @doc "Delete a run's results (a discarded run leaves nothing behind)."
  def delete_run(workflow_run) do
    {count, _} =
      Repo.delete_all(from(r in Result, where: r.workflow_run == ^to_string(workflow_run)))

    count
  end

  @doc """
  The hash of a node's rendered inputs.

  Canonicalized before hashing -- maps become key-sorted lists -- so two
  argument maps that differ only in key order hash the same. Without that,
  a resume would re-run every node whose args were rebuilt in a different
  order, which is the normal case, and the key would buy nothing.
  """
  def args_hash(args) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical(args)))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%{__struct__: _} = struct), do: canonical(Map.from_struct(struct))

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp load(nil), do: nil

  defp load(%Result{} = row) do
    %{
      workflow_run: row.workflow_run,
      workflow: row.workflow,
      stage: row.stage,
      node_name: row.node_name,
      args_hash: row.args_hash,
      result: Jason.decode!(row.result),
      artifact: row.artifact,
      attempt_id: row.attempt_id,
      validation: row.validation,
      at: row.at
    }
  end
end
