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

  require Logger

  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.NodeJob
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run

  @digest_limit 2_000

  @doc """
  Open a run and enqueue its first stage. `workflow` is a catalog name or a
  `%Custode.Workflow{}`; `repo` is the `owner/name` the nodes read.

  Options:

    * `:working_dir` -- where the nodes run. Defaults to the working_dir of the
      routine serving `repo`, else the current directory.
    * `:context` -- extra render bindings, available to prompts as `@context`.
      Stored on the run, so a resume renders what the launch rendered.
    * `:max_budget_usd` -- per-node cost ceiling. The RUN-level rail is slice 2;
      this is the per-call cap every claude run in the fleet already carries.
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

      Run.start(run_id, definition.name, repo, first.name, context)
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

  Not wired into the supervision tree this slice: launching is iex-only until
  the gate lands, so there is no unattended run to rescue, and an
  enqueue-on-boot side effect belongs with the run-level budget rail that
  bounds it (slice 2).
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
    Run.fail(run_id, "node #{meta["node_name"]} failed: #{inspect(reason)}")
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

      if pending == [] do
        next_stage(run, definition, stage)
      else
        Enum.each(pending, &enqueue(run, definition, stage, &1))
        {:ok, Run.get(run.run_id)}
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

  defp next_stage(run, definition, stage) do
    case after_stage(definition, stage) do
      nil ->
        {:ok, Run.complete(run.run_id)}

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

  defp resolve(%Workflow{} = definition), do: {:ok, definition}
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

  defp text_of(%{result: text}) when is_binary(text), do: text
  defp text_of(_), do: "(no text)"
end
