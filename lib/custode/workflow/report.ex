defmodule Custode.Workflow.Report do
  @moduledoc """
  A finished run's report artifact: the markdown a synthesis node produced,
  written to a file and named in the feed (design/005 slice 5, #275).

  design/002 puts records in the database and long documents on disk, and a
  30-page report is the case it had in mind: the row keeps the structured
  result, the file keeps the prose, and `workflow_node_results.artifact`
  points from one to the other. The janitor already retires the pair
  together -- this is the writer that gives it something to retire.

  ## Custode writes it, not the node

  design/005's "nodes that write" non-goal rules out a node saving its own
  report: nodes read the target repo and return data, and a turn that writes
  files into a checkout is exactly the reach the fleet withholds. So the
  markdown comes back inside the node's schema-forced result like every
  other node output, and this module writes it -- under the run's OWN
  artifact directory (`Custode.Home`'s data dir), never into the repo the
  run was reading.

  ## A missing report is a note, not a failure

  A run whose synthesis node returned no markdown has still done all its
  work, and failing it would throw away every result to punish a bad last
  turn. The run completes with a note saying no report was written, which is
  the same no-silent-caps rule a zero-item fan-out follows: what did not
  happen is on the record rather than absent from it.
  """

  require Logger

  alias Custode.Workflow
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run

  @doc """
  Write the run's report, if its workflow declares one.

  Returns `{:ok, path}`, `:none` (the workflow declares no report), or
  `{:error, reason}` after noting the reason on the run.
  """
  def write(_run, %Workflow{report: nil}), do: :none

  def write(run, %Workflow{report: %{node: node, key: key, filename: filename}}) do
    with {:ok, result} <- result_of(run, node),
         {:ok, markdown} <- markdown_of(result, key) do
      save(run, result, markdown, filename)
    else
      {:error, reason} ->
        Run.note(run.run_id, reason)
        {:error, reason}
    end
  end

  @doc """
  Where a run's artifacts live: `artifact_dir` from its context, else the
  run's working directory.

  The runner stamps `artifact_dir` at launch so a resume writes where the
  launch would have. The fallback covers a run recorded before this existed,
  which is also what `Custode.Janitor` falls back to when it decides whether
  an artifact is inside the tree it may delete from.
  """
  def dir(run) do
    context = Map.get(run, :context) || %{}

    Path.expand(context["artifact_dir"] || context["working_dir"] || File.cwd!())
  end

  @doc "The default artifact directory for a run id, under the data dir."
  def default_dir(run_id) do
    Custode.Home.resolve_in(&Custode.Home.data_dir/0, Path.join("workflows", to_string(run_id)))
  end

  defp result_of(run, node) do
    run.run_id
    |> Results.for_run()
    |> Enum.find(&(&1.node_name == to_string(node)))
    |> case do
      nil -> {:error, "no report written: node #{node} produced no result"}
      result -> {:ok, result}
    end
  end

  defp markdown_of(result, key) do
    case Map.get(result.result, key) do
      markdown when is_binary(markdown) ->
        if String.trim(markdown) == "",
          do: {:error, "no report written: #{result.node_name} returned an empty #{key}"},
          else: {:ok, markdown}

      _missing ->
        {:error, "no report written: #{result.node_name}'s result carries no #{key}"}
    end
  end

  defp save(run, result, markdown, filename) do
    path = Path.join(dir(run), filename)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, markdown) do
      Results.set_artifact(run.run_id, result.node_name, result.args_hash, path)
      {:ok, path}
    else
      {:error, posix} ->
        reason = "no report written: #{path} could not be written (#{:file.format_error(posix)})"
        Logger.warning("workflow #{run.run_id}: #{reason}")
        {:error, reason}
    end
  end
end
