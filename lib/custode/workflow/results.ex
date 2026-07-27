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

  `put/2` upserts on that key: a retried node overwrites its own row rather
  than accumulating near-duplicates. Same key means same inputs, so the
  newest run of it is the one to keep.

  ## Retention (#39)

  `Custode.Janitor` retires these rows with their run, once that run has
  FINISHED and its `finished_at` is past `janitor: [workflow_runs_days: N]`.
  A run still `running` or `budget_paused` keeps every result however old it
  is -- they are what a resume reads instead of re-running the nodes.
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
      field(:at, :utc_datetime_usec)
    end
  end

  @doc """
  Record one node's result. `attrs` takes `:workflow_run`, `:workflow`,
  `:stage`, `:node_name`, `:args_hash`, the `:result` map, and an optional
  `:artifact` path. Returns the stored map.
  """
  def put(attrs) do
    row = %Result{
      workflow_run: to_string(attrs.workflow_run),
      workflow: to_string(attrs.workflow),
      stage: to_string(attrs.stage),
      node_name: to_string(attrs.node_name),
      args_hash: attrs.args_hash,
      result: Jason.encode!(Map.get(attrs, :result) || %{}),
      artifact: Map.get(attrs, :artifact),
      at: DateTime.utc_now()
    }

    Repo.insert!(row,
      on_conflict: {:replace, [:result, :artifact, :stage, :workflow, :at]},
      conflict_target: [:workflow_run, :node_name, :args_hash]
    )

    load(row)
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
      at: row.at
    }
  end
end
