defmodule Custode.Workflow.Runner do
  @moduledoc """
  Walks a `Custode.Workflow` definition: enqueue the current stage's nodes,
  advance when they have all landed, stop when there is no stage left
  (design/005 slice 1b, #271).

  This is the second instance of the enqueue-and-advance seam
  `ObanClaude.Agent` established: something enqueues a job, the job reports
  back when it terminates, and the reporter decides what happens next.
  `Custode.Workflow.NodeJob` is the `ObanClaude.Agent.Job` analogue and
  `node_finished/2` the `job_finished/2` analogue. The design says not to merge
  the two yet -- an agent threads one session, a node is a one-shot -- and this
  keeps the shapes recognisably the same without sharing code.

  ## No process per run

  design/005 sketches "one process per run". This runs the walk in the
  reporting job's own callback instead, and the deviation is deliberate: with
  the run row and the node results both persisted, a per-run process would
  hold no state that is not already in the database, and it would add a way
  for a run to die silently. Every question the walk asks -- which stage, what
  has landed, what is missing -- is a query, so the walk is a function over
  the record. What a process would have bought is the one case where nothing
  calls back: the app restarting while a stage barrier is complete. `resume/1`
  and `resume_all/0` cover that, called by hand this slice (launching is iex-
  only until the gate lands).

  ## Stages are barriers

  `advance/1` enqueues every node of the current stage that has no persisted
  result, and moves the cursor only when they ALL have one. Re-enqueueing an
  in-flight node would be a second paid claude call, so `NodeJob` is unique on
  `{workflow_run, node_name, args_hash}` across every live and completed
  state: the second insert is a no-op at the database, not a race this module
  has to win.

  ## Digests, not transcripts

  A node's prompt is rendered with `@digests` -- the previous stage's results,
  each truncated to #{2_000} characters. Late-stage prompts stay bounded no
  matter how verbose the miners were, and a truncated digest says so rather
  than trailing off.

  ## Fan-out

  A `per_item` stage expands over the `"items"` array of every result in the
  stage before it, in order, one node per item named `<template>_<n>`. A stage
  feeding a `per_item` stage must therefore produce `items` in its schema. An
  expansion to zero items is legal (a verify stage after a merge that found
  nothing) and is recorded on the run's notes, because a stage that quietly
  did nothing otherwise reads exactly like a stage that had nothing to do.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Launch
  alias Custode.Workflow.NodeJob
  alias Custode.Workflow.Report
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run

  @digest_limit 2_000

  @doc """
  Open a run and enqueue its first stage. `workflow` is a CATALOG NAME and
  `repo` the `owner/name` the nodes read.

  A name rather than a definition because a run has to be resolvable from its
  own record: the row stores the name, and every later advance looks the
  definition back up. A run launched from a definition nothing can find again
  would walk one stage and then stall. `:extra_workflows` is the seam for a
  definition that is not in the built-in catalog.

  Options:

    * `:working_dir` -- where the nodes run. Defaults to the working_dir of the
      routine serving `repo`, else the current directory.
    * `:context` -- extra render bindings, available to prompts as `@context`.
      Stored on the run, so a resume renders what the launch rendered.
    * `:max_budget_usd` -- per-node cost ceiling, the per-call cap every claude
      run in the fleet already carries.
    * `:budget_usd` -- the RUN's rail (slice 2): total spend across every node,
      after which the run parks at `budget_paused`. nil is unbounded, which is
      what an iex launch gets; the launch gate always sets one.
    * `:run_id` -- override the minted id (tests, and re-running a known run).

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  def launch(workflow, repo, opts \\ []) do
    with {:ok, definition} <- resolve(workflow),
         :ok <- Workflow.validate(definition) do
      run_id = Keyword.get(opts, :run_id) || mint_run_id(definition.name)
      [first | _] = definition.stages

      context =
        opts
        |> Keyword.get(:context, %{})
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("working_dir", working_dir(repo, opts))
        |> Map.put("max_budget_usd", per_node_budget(opts))
        # where a report artifact lands (slice 5). Stored on the run rather
        # than derived at write time, so a resume writes where the launch
        # would have, and the janitor can tell later which tree it may delete
        # the file from.
        |> Map.put_new("artifact_dir", Report.default_dir(run_id))

      run =
        Run.start(
          run_id,
          definition.name,
          repo,
          first.name,
          context,
          Keyword.get(opts, :budget_usd)
        )

      record(run, "workflow_launched", launch_summary(definition, run))
      advance(run_id)
    end
  end

  @doc """
  Walk the run forward: enqueue what the current stage is missing, or move the
  cursor when it is complete. Idempotent -- calling it twice enqueues nothing
  twice -- so it is safe from a node callback, from `resume_all/0`, and from
  iex.

  Returns `{:ok, run}` with the run as it now stands, or `{:error, reason}`.
  """
  def advance(run_id) do
    case Run.get(run_id) do
      nil -> {:error, :no_such_run}
      %{status: "running"} = run -> advance_running(run)
      run -> {:ok, run}
    end
  end

  @doc """
  Alias for `advance/1`, named for the case it exists to serve: the app
  restarted and nothing is going to call back.
  """
  def resume(run_id), do: advance(run_id)

  @doc """
  Advance every run still marked running. The restart path -- a run whose last
  node landed while the app was down has no other way to move.

  Wired into the supervision tree as of slice 2, now that the run-level rail
  bounds what a boot can restart. A `budget_paused` run is not `running`, so
  this never wakes one the operator has not let go.
  """
  def resume_all do
    for run <- Run.list(status: "running"), do: {run.run_id, advance(run.run_id)}
  end

  @doc """
  A node reported in. Persists its result and walks the run forward -- the
  `ObanClaude.Agent.job_finished/2` analogue.

  A result that did not honour its schema is stored as its text under `"text"`
  and noted on the run rather than dropped: a downstream digest of prose is
  worse than a digest of JSON, and silently nothing is worse than both.
  """
  def node_finished(%{"workflow_run" => run_id} = meta, result) do
    {payload, note} =
      case ObanClaude.structured(result) do
        %{} = structured ->
          {structured, nil}

        _ ->
          {%{"text" => text_of(result)},
           "node #{meta["node_name"]} returned no schema-shaped result; stored its text"}
      end

    Results.put(%{
      workflow_run: run_id,
      workflow: meta["workflow"],
      stage: meta["stage"],
      node_name: meta["node_name"],
      args_hash: meta["args_hash"],
      result: payload
    })

    if note, do: Run.note(run_id, note)

    advance(run_id)
  end

  def node_finished(_meta, _result), do: :ok

  @doc """
  A node failed terminally. The run fails with it: a workflow whose merge node
  never ran has nothing honest to hand the stages below it, and half a sweep
  presented as a whole sweep is the outcome design/005 rules out. The stage
  cursor and every result so far stay on the record.
  """
  def node_failed(%{"workflow_run" => run_id} = meta, reason) do
    detail = "node #{meta["node_name"]} failed: #{inspect(reason)}"
    failed = Run.fail(run_id, detail)
    if failed, do: record(failed, "workflow_failed", detail)
    failed
  end

  def node_failed(_meta, _reason), do: :ok

  @doc """
  The nodes the current stage would enqueue, rendered. Exposed because it is
  what the launch gate's estimate reads (slice 2) and what makes a fan-out
  inspectable before it is paid for.
  """
  def plan(%{} = run, %Workflow{} = definition) do
    case Workflow.stage(definition, stage_name(definition, run.stage)) do
      nil -> []
      stage -> plan_stage(run, definition, stage)
    end
  end

  # ---------------------------------------------------------------------------
  # the walk
  # ---------------------------------------------------------------------------

  defp advance_running(run) do
    with {:ok, definition} <- resolve(run.workflow),
         %Workflow.Stage{} = stage <-
           Workflow.stage(definition, stage_name(definition, run.stage)) do
      planned = plan_stage(run, definition, stage)
      pending = Enum.reject(planned, &landed?(run, &1))

      cond do
        pending == [] -> next_stage(run, definition, stage)
        Launch.over_rail?(run) -> park(run, pending)
        true -> enqueue_all(run, definition, stage, pending)
      end
    else
      :error ->
        Run.fail(run.run_id, "unknown workflow #{run.workflow}")
        {:error, :unknown_workflow}

      nil ->
        Run.fail(run.run_id, "unknown stage #{run.stage}")
        {:error, :unknown_stage}
    end
  end

  defp enqueue_all(run, definition, stage, pending) do
    Enum.each(pending, &enqueue(run, definition, stage, &1))
    {:ok, Run.get(run.run_id)}
  end

  # The rail is reached. The stage's outstanding nodes are cancelled rather
  # than left available, because a paused run with jobs still in the queue
  # would keep spending -- and NodeJob's unique key excludes cancelled, so a
  # resume re-enqueues exactly these.
  defp park(run, pending) do
    names = Enum.map(pending, & &1.node_name)
    cancel_pending(run.run_id)

    spend = Launch.spend(run)

    reason =
      "run budget rail hit: $#{usd(spend.spent_usd)} of $#{usd(spend.budget_usd)}"

    Run.budget_pause(run.run_id, reason, names)

    record(
      run,
      "workflow_budget_paused",
      reason <> " -- #{length(names)} node(s) not run: #{Enum.join(names, ", ")}"
    )

    {:ok, Run.get(run.run_id)}
  end

  defp cancel_pending(run_id) do
    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where: j.worker == "Custode.Workflow.NodeJob",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run_id
      )
    )
  end

  defp next_stage(run, definition, stage) do
    record(run, "workflow_stage_complete", "stage #{stage.name} complete")

    case after_stage(definition, stage) do
      nil ->
        # the report is written before the run is marked complete, so its
        # note (a synthesis node that returned no markdown) is on the record
        # the completion summary counts
        report = Report.write(run, definition)
        finished = Run.complete(run.run_id)
        record(finished, "workflow_complete", complete_summary(finished))
        report_recorded(finished, report)
        {:ok, finished}

      %Workflow.Stage{} = next ->
        Run.set_stage(run.run_id, next.name)
        # straight into the next stage, so an empty fan-out cascades rather
        # than parking the run on a stage that will never report in
        advance(run.run_id)
    end
  end

  defp after_stage(%Workflow{stages: stages}, stage) do
    stages
    |> Enum.drop_while(&(&1.name != stage.name))
    |> Enum.at(1)
  end

  defp landed?(run, planned) do
    not is_nil(Results.fetch(run.run_id, planned.node_name, planned.args_hash))
  end

  # ---------------------------------------------------------------------------
  # planning a stage
  # ---------------------------------------------------------------------------

  defp plan_stage(run, definition, %Workflow.Stage{per_item: true, nodes: [template]} = stage) do
    digests = digests(run, definition, stage)

    case fan_out_items(run, definition, stage) do
      [] ->
        Run.note(
          run.run_id,
          "stage #{stage.name} fanned out over 0 items (no \"items\" upstream)"
        )

        []

      items ->
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {item, index} ->
          build(run, definition, stage, template, "#{template.name}_#{index}",
            digests: digests,
            item: item
          )
        end)
    end
  end

  defp plan_stage(run, definition, %Workflow.Stage{} = stage) do
    digests = digests(run, definition, stage)

    Enum.map(stage.nodes, fn node ->
      build(run, definition, stage, node, to_string(node.name), digests: digests, item: nil)
    end)
  end

  defp build(run, definition, stage, node, node_name, bindings) do
    settings = Workflow.settings(definition, stage, node)

    prompt =
      render(node.prompt,
        repo: run.repo,
        run: run.run_id,
        workflow: definition.name,
        stage: stage.name,
        node: node_name,
        digests: bindings[:digests],
        item: encode_item(bindings[:item]),
        context: run.context
      )

    # the hash covers everything that determines the run: the rendered prompt
    # (which carries the upstream digests, so an upstream edit invalidates
    # everything below it), the schema, and the model/effort it runs under
    args_hash =
      Results.args_hash(%{
        prompt: prompt,
        schema: node.schema,
        model: settings.model,
        effort: settings.effort
      })

    %{
      node: node,
      node_name: node_name,
      prompt: prompt,
      settings: settings,
      args_hash: args_hash
    }
  end

  # a per_item stage fans out over the "items" of every result in the stage
  # before it, concatenated in stage order
  defp fan_out_items(run, definition, stage) do
    case previous_stage(definition, stage) do
      nil ->
        []

      previous ->
        run.run_id
        |> Results.for_stage(previous.name)
        |> Enum.flat_map(&items_of/1)
    end
  end

  defp items_of(%{result: %{"items" => items}}) when is_list(items), do: items
  defp items_of(_result), do: []

  defp previous_stage(%Workflow{stages: stages}, stage) do
    stages
    |> Enum.take_while(&(&1.name != stage.name))
    |> List.last()
  end

  defp digests(run, definition, stage) do
    case previous_stage(definition, stage) do
      nil ->
        "(none -- this is the first stage)"

      previous ->
        run.run_id
        |> Results.for_stage(previous.name)
        |> Enum.map_join("\n\n", &digest/1)
        |> case do
          "" -> "(the #{previous.name} stage produced no results)"
          text -> text
        end
    end
  end

  defp digest(result) do
    json = Jason.encode!(result.result)

    body =
      if String.length(json) > @digest_limit do
        String.slice(json, 0, @digest_limit) <>
          "\n... (truncated: #{String.length(json)} characters total)"
      else
        json
      end

    "### #{result.node_name}\n#{body}"
  end

  defp encode_item(nil), do: nil
  defp encode_item(item) when is_binary(item), do: item
  defp encode_item(item), do: Jason.encode!(item)

  @doc """
  Render a node's prompt template. EEx with assigns: `@repo`, `@digests`,
  `@item` (a per_item node's item, JSON), `@workflow`, `@stage`, `@node`,
  `@run`, `@context`.
  """
  def render(template, assigns) do
    EEx.eval_string(template, assigns: assigns)
  end

  # ---------------------------------------------------------------------------
  # enqueueing
  # ---------------------------------------------------------------------------

  defp enqueue(run, definition, stage, planned) do
    args =
      [
        prompt: planned.prompt,
        working_dir: Path.expand(run.context["working_dir"] || File.cwd!()),
        json_schema: Jason.encode!(planned.node.schema),
        max_budget_usd: run.context["max_budget_usd"] || default_budget(),
        max_turns: 30,
        timeout: 900_000
      ]
      |> put_unless_nil(:model, planned.settings.model)
      |> put_effort(planned.settings.effort)
      |> ObanClaude.Args.new()

    meta = %{
      "workflow_run" => run.run_id,
      "workflow" => definition.name,
      "stage" => to_string(stage.name),
      "node_name" => planned.node_name,
      "args_hash" => planned.args_hash,
      # spend attribution: a run's cost is readable per run, which is what the
      # gate's estimate (slice 2) will calibrate against
      "agent_id" => "workflow-" <> run.run_id
    }

    case args |> NodeJob.new(meta: meta) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "workflow #{run.run_id}: could not enqueue #{planned.node_name}: #{inspect(reason)}"
        )

        Run.fail(run.run_id, "could not enqueue #{planned.node_name}: #{inspect(reason)}")
    end
  end

  defp put_unless_nil(args, _key, nil), do: args
  defp put_unless_nil(args, key, value), do: Keyword.put(args, key, value)

  defp put_effort(args, nil), do: args

  defp put_effort(args, effort) when is_binary(effort),
    do: Keyword.put(args, :effort, String.to_existing_atom(effort))

  defp put_effort(args, effort) when is_atom(effort), do: Keyword.put(args, :effort, effort)

  # ---------------------------------------------------------------------------
  # odds and ends
  # ---------------------------------------------------------------------------

  defp resolve(name) when is_binary(name), do: Catalog.fetch(name)
  defp resolve(name) when is_atom(name), do: Catalog.fetch(to_string(name))

  # run.stage comes back from the database as a string; stage names are atoms
  # in the definition, so match by rendered name rather than converting
  defp stage_name(%Workflow{stages: stages}, stage) do
    Enum.find_value(stages, fn s -> if to_string(s.name) == to_string(stage), do: s.name end)
  end

  defp mint_run_id(workflow) do
    stamp = DateTime.utc_now() |> DateTime.to_unix()
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{workflow}-#{stamp}-#{suffix}"
  end

  defp working_dir(repo, opts) do
    Keyword.get(opts, :working_dir) || routine_dir(repo) || File.cwd!()
  end

  defp routine_dir(repo) do
    Custode.Routine.all()
    |> Enum.find(&(Map.get(&1, :repo) == repo))
    |> case do
      nil -> nil
      routine -> routine.working_dir
    end
  end

  defp per_node_budget(opts), do: Keyword.get(opts, :max_budget_usd) || default_budget()

  defp default_budget, do: Application.fetch_env!(:custode, :max_budget_usd)

  # ---------------------------------------------------------------------------
  # the feed (design/005 point 6)
  # ---------------------------------------------------------------------------

  # A run's milestones go into the same feed everything else does -- launch,
  # each stage barrier, the finish, the rail. No bespoke counters: the
  # checklist card, the Digest and any future advisor read this stream
  # (emit-from-birth, design/004 D1).
  #
  # `agent` stays nil rather than naming the run's spend agent id: the feed's
  # agent column is the click-through to an agent page, and a workflow run has
  # no such page. The run id rides its own field.
  defp record(run, event, summary) do
    Custode.Feed.record(%{
      event: event,
      agent: nil,
      run: run.run_id,
      workflow: run.workflow,
      repo: run.repo,
      summary: "#{run.workflow} [#{run.run_id}] #{summary}"
    })
  end

  # design/005 slice 5: the report is "saved to the workspace and linked from
  # the feed". The path rides its own field as well as the summary, so a
  # future page can offer the file without re-parsing prose. A run that wrote
  # no report records nothing here -- its note already says why, and a feed
  # entry announcing an absence would read like a failure.
  defp report_recorded(run, {:ok, path}) do
    Custode.Feed.record(%{
      event: "workflow_report",
      agent: nil,
      run: run.run_id,
      workflow: run.workflow,
      repo: run.repo,
      artifact: path,
      summary: "#{run.workflow} [#{run.run_id}] report saved: #{path}"
    })
  end

  defp report_recorded(_run, _other), do: :ok

  defp launch_summary(definition, run) do
    {known, fans_out} = Workflow.node_floor(definition)
    count = if fans_out, do: "at least #{known} nodes", else: "#{known} nodes"

    rail =
      case run.budget_usd do
        nil -> "no rail"
        budget -> "rail $#{usd(budget)}"
      end

    "launched on #{run.repo}: #{count}, #{rail}"
  end

  defp complete_summary(run) do
    results = length(Results.for_run(run.run_id))
    notes = length(run.notes)
    spent = usd(Run.spent(run.run_id))

    # the notes count rides the summary so a run that skipped something never
    # reads, at a glance, like one that did not
    "complete: #{results} node results, $#{spent}" <>
      if(notes > 0, do: ", #{notes} note(s) on what it did not do", else: "")
  end

  defp usd(nil), do: "none"
  defp usd(amount) when is_number(amount), do: :erlang.float_to_binary(amount / 1, decimals: 2)

  defp text_of(%ClaudeWrapper.Result{result: text}), do: text
end
