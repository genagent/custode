defmodule Custode.Workflow.NodeJob do
  @moduledoc """
  One workflow node as an Oban job: run claude with the node's rendered prompt
  and `--json-schema`, then report to `Custode.Workflow.Runner` (design/005
  slice 1b, #271).

  The `ObanClaude.Agent.Job` analogue -- the run identity rides in the job's
  meta, where the runner puts it at enqueue time, and a job without a
  `"workflow_run"` runs normally and reports to no one.

  ## The queue

  `:workflows` at concurrency 1, its own queue so a deep dig never starves the
  sweeps and is exactly as sequential as everything else in the fleet
  (position 5). The DAG says what depends on what; the queue says how many run
  at once, and those are separable.

  ## Unique

  Keyed on `{workflow_run, node_name, args_hash}` across every live and
  completed state. The runner advances on each node's return, so it re-plans a
  stage while that stage's other nodes are still in flight; without this, every
  return would re-enqueue its siblings and each one would be a second paid
  claude call. Discarded and cancelled jobs are outside the key's states, so a
  dead node can be re-planned.

  ## Named write tools are disabled

  `Write`, `Edit`, and `NotebookEdit` are pinned off. This does not mechanically
  confine Bash, native settings or MCP write operations. Nodes are instructed
  to analyse and draft; that instruction is not a side-effect replay guarantee.
  Oban terminal state also does not attest physical process settlement. Failed
  stage retry remains unavailable until those worker boundaries are proved.
  """

  use ObanClaude.Worker,
    queue: :workflows,
    max_attempts: 1,
    pinned_args: ObanClaude.Args.defaults(disallowed_tools: ["Write", "Edit", "NotebookEdit"]),
    unique: [
      fields: [:worker, :meta],
      keys: [:workflow_run, :node_name, :args_hash],
      period: :infinity,
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  alias Custode.Workflow.{ResultContract, Runner}

  @doc """
  The args pinned over every node job. They are merged in `perform/1`, not at
  enqueue time, so they are not in a stored job's args -- this is where the
  named-tool restrictions are readable; this is not a general no-write guarantee.
  """
  def pinned_args, do: @oban_claude_pinned_args

  @impl Oban.Worker
  def perform(job) do
    case ResultContract.launch_check(job) do
      :ok -> super(job)
      {:error, reason} -> handle_error({:cancel, reason}, nil, job)
    end
  end

  @impl ObanClaude.Worker
  def handle_result(result, %Oban.Job{id: id, meta: %{"workflow_run" => _} = meta} = job) do
    Runner.node_finished(
      Map.merge(meta, %{"callback_job_id" => id, "callback_attempt" => job.attempt}),
      result
    )

    :ok
  end

  def handle_result(_result, _job), do: :ok

  @impl ObanClaude.Worker
  def handle_error(
        oban_return,
        _payload,
        %Oban.Job{id: id, meta: %{"workflow_run" => _} = meta} = job
      ) do
    Runner.node_failed(
      Map.merge(meta, %{"callback_job_id" => id, "callback_attempt" => job.attempt}),
      oban_return
    )

    oban_return
  end

  def handle_error(oban_return, _payload, _job), do: oban_return
end
