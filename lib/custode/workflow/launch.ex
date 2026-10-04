defmodule Custode.Workflow.Launch do
  @moduledoc """
  The launch gate: a workflow run is proposed, priced, and approved by a
  human before a single node is paid for (design/005 slice 2, #271).

  design/005 is explicit that launch is gate-mediated and that there is no
  second path -- the button (slice 3) and the agent suggestion (slice 4) both
  arrive HERE. So this module is the whole surface: `propose/3` opens a gate
  card, `approve/1` starts the run, `reject/2` closes it.

  ## Why not `Custode.Gates`

  That table records the states of an `ObanClaude.Agent` gen_statem, keyed to
  a machine that is waiting. Nothing is waiting for a workflow launch: there
  is no run and no process until the operator says yes. The shape this
  actually matches is `Custode.Suggestions` -- a standing proposal in the
  feed, masked once resolved -- so it is built the same way, and the feed
  stays the one telemetry substrate everything reads (emit-from-birth).

  ## The estimate

  Nodes x the repo's observed per-turn cost from the spend ledger, which is
  the only number here that is not invented. Two things it refuses to fake:

    * a workflow that fans out has no knowable node count before its merge
      stage runs, so the card quotes the FLOOR and says the rest is not
      knowable (`Custode.Workflow.node_floor/1`);
    * a repo the fleet has never spent on has no observed cost, so the
      estimate falls back to the per-node cap and says the number is a
      ceiling, not a prediction.

  A run whose estimate turns out low is not silently truncated either: the
  rail (`Custode.Workflow.Run.budget_pause/3`) parks it with a note naming
  what it did not do.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Feed
  alias Custode.Repo
  alias Custode.SpendLedger
  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner

  # A proposal that has sat unanswered for a week is stale -- the backlog it
  # was priced against has moved. Same window as the advisor suggestions.
  @window_s 7 * 24 * 60 * 60

  @proposed "workflow_launch_proposed"
  @approved "workflow_launch_approved"
  @rejected "workflow_launch_rejected"

  @doc """
  Price a run without proposing anything. Returns a map the gate card and the
  `mix` task both render:

    * `:known_nodes` / `:fans_out` -- the floor, and whether it is only a floor
    * `:per_node_usd` / `:basis` / `:sample` -- the ledger read behind it
      (`:observed` with a sample size, or `:default` when there is no history)
    * `:floor_usd` -- `known_nodes * per_node_usd`
    * `:total_usd` -- the same number when the count is exact, nil when the
      workflow fans out (there is no total to quote yet)
    * `:budget_usd` -- the rail the run would carry

  `{:error, :unknown_workflow}` for a name the catalog does not have.
  """
  def estimate(workflow, repo, opts \\ []) do
    case Catalog.fetch(to_string(workflow)) do
      :error ->
        {:error, :unknown_workflow}

      {:ok, definition} ->
        {known, fans_out} = Workflow.node_floor(definition)
        {per_node, basis, sample} = per_node_cost(repo)

        {:ok,
         %{
           workflow: definition.name,
           repo: to_string(repo),
           known_nodes: known,
           fans_out: fans_out,
           per_node_usd: per_node,
           basis: basis,
           sample: sample,
           floor_usd: known * per_node,
           total_usd: if(fans_out, do: nil, else: known * per_node),
           budget_usd: Keyword.get(opts, :budget_usd) || default_budget()
         }}
    end
  end

  @doc """
  Open a launch gate. Records a `workflow_launch_proposed` feed entry
  carrying the estimate, and returns `{:ok, proposal}` with the `:id` that
  `approve/1` and `reject/2` take.

  Options: `:budget_usd` (the run's rail), `:working_dir`, `:context`,
  `:max_budget_usd` (the per-node cap), and `:why` -- one line saying what
  prompted the proposal, which is what makes an agent-raised gate (slice 4)
  readable rather than an unexplained bill.
  """
  def propose(workflow, repo, opts \\ []) do
    with {:ok, estimate} <- estimate(workflow, repo, opts) do
      proposal =
        estimate
        |> Map.put(:id, mint_id())
        |> Map.put(:why, Keyword.get(opts, :why))
        |> Map.put(:launch_opts, launch_opts(opts))

      # `notify: true` (#447): a launch gate waits on the operator and on
      # nobody else, which is what the desktop notification is for. Before,
      # it reached ntfy only, and ntfy is off unless a topic is configured.
      Feed.record(
        %{
          event: @proposed,
          agent: nil,
          proposal: proposal.id,
          workflow: proposal.workflow,
          repo: proposal.repo,
          estimate: Map.drop(proposal, [:launch_opts]),
          launch_opts: proposal.launch_opts,
          why: proposal.why,
          summary: summary(proposal)
        },
        notify: true
      )

      {:ok, proposal}
    end
  end

  @doc """
  Every launch gate still standing, newest first. A proposal leaves the list
  once approved or rejected -- the resolving entry masks it by proposal id.
  """
  def pending do
    # Proposals first, and nothing else when there are none. This now runs
    # under every attention read (#447), and "no proposal this week" is the
    # common case by a wide margin.
    case Feed.recent_by_event(@proposed, limit: 50, since: @window_s) do
      [] ->
        []

      proposed ->
        resolved =
          for event <- [@approved, @rejected],
              entry <- Feed.recent_by_event(event, limit: 50, since: @window_s),
              into: MapSet.new(),
              do: entry["proposal"]

        Enum.reject(proposed, &(&1["proposal"] in resolved))
    end
  end

  @doc """
  Every standing gate as `%{repo => %{workflow => proposal_id}}`.

  A second proposal for a pair that already has one is noise -- the operator
  has one decision to make, not two. The button (slice 3) offers the standing
  gate instead of minting a duplicate, and the dryness advisor (slice 4) stays
  quiet; both read this so the two entry points cannot drift into different
  ideas of what "already proposed" means.
  """
  def standing do
    pending()
    |> Enum.group_by(& &1["repo"])
    |> Map.new(fn {repo, entries} ->
      {repo, Map.new(entries, &{&1["workflow"], &1["proposal"]})}
    end)
  end

  @doc "The standing gates for one repo, as `%{workflow => proposal_id}`."
  def standing_for(repo), do: Map.get(standing(), to_string(repo), %{})

  @doc """
  Was this workflow/repo pair rejected inside the proposal window?

  The answer an agent-raised proposal needs and a clicked one does not: a
  human who clicks the button has just decided to ask again, while an advisor
  firing on a cron would re-propose every day against a "no" that has not
  aged out. The rejection in the feed IS the cooldown -- no second seen-set to
  keep in sync with it.
  """
  def recently_rejected?(workflow, repo) do
    workflow = to_string(workflow)
    repo = to_string(repo)

    @rejected
    |> Feed.recent_by_event(limit: 50, since: @window_s)
    |> Enum.any?(&(&1["workflow"] == workflow and &1["repo"] == repo))
  end

  @doc """
  Approve a standing proposal: record the decision and start the run.

  The run is launched with the rail the card quoted, so what the operator
  approved and what the run enforces are the same number. Returns
  `{:ok, run}`, or `{:error, :no_such_proposal}` for an id that is not
  standing (an already-answered gate cannot be answered twice).
  """
  def approve(proposal_id) do
    case find(proposal_id) do
      nil ->
        {:error, :no_such_proposal}

      entry ->
        opts = launch_opts_of(entry)

        case Runner.launch(entry["workflow"], entry["repo"], opts) do
          {:ok, run} ->
            Feed.record(%{
              event: @approved,
              agent: nil,
              proposal: proposal_id,
              workflow: entry["workflow"],
              repo: entry["repo"],
              run: run.run_id,
              summary:
                "approved #{entry["workflow"]} on #{entry["repo"]} -- run #{run.run_id}, " <>
                  "rail $#{fmt(opts[:budget_usd])}"
            })

            {:ok, run}

          {:error, reason} ->
            # the gate stays standing: a launch that could not start is not a
            # decision the operator has to take again
            {:error, reason}
        end
    end
  end

  @doc "Reject a standing proposal. The reason rides the feed entry."
  def reject(proposal_id, reason \\ "rejected from the dashboard") do
    case find(proposal_id) do
      nil ->
        {:error, :no_such_proposal}

      entry ->
        Feed.record(%{
          event: @rejected,
          agent: nil,
          proposal: proposal_id,
          workflow: entry["workflow"],
          repo: entry["repo"],
          summary: "rejected #{entry["workflow"]} on #{entry["repo"]}: #{reason}"
        })

        :ok
    end
  end

  @doc """
  Let a budget-paused run go on, optionally on a raised rail. Records the
  decision in the feed and advances the run -- resuming onto an unraised rail
  parks it again immediately, which is the honest answer rather than a silent
  overrun.
  """
  def unpause(run_id, opts \\ []) do
    case Run.get(run_id) do
      nil ->
        {:error, :no_such_run}

      %{status: "budget_paused"} = run ->
        budget = Keyword.get(opts, :budget_usd, :keep)
        Run.unpause(run_id, budget)

        Feed.record(%{
          event: "workflow_resumed",
          agent: nil,
          run: run.run_id,
          workflow: run.workflow,
          repo: run.repo,
          summary:
            "resumed #{run.workflow} run #{run.run_id}" <>
              if(budget == :keep, do: " on its existing rail", else: " on a $#{fmt(budget)} rail")
        })

        Runner.advance(run_id)

      _running ->
        {:error, :not_paused}
    end
  end

  @doc """
  Let a parked run go on with its rail DOUBLED: the one act every surface
  offers for a budget pause (#447).

  Resuming onto the same ceiling parks the run again on its next advance, so
  the button raises the rail rather than pretending the limit is gone. The
  factor lives here because the workflows page and the inbox both offer the
  button, and two pages must not come to hold two ideas of what it does. A run
  with no rail is resumed as it is.
  """
  def raise_and_resume(run_id) do
    case Run.get(run_id) do
      %{budget_usd: budget} when is_number(budget) -> unpause(run_id, budget_usd: budget * 2)
      _no_rail_or_no_run -> unpause(run_id)
    end
  end

  @doc """
  Runs worth showing, newest first: everything still live, then the last few
  finished ones. The checklist card reads this.
  """
  def recent(limit \\ 10) do
    live = Run.list(status: "running") ++ Run.list(status: "budget_paused")
    finished = Run.list(status: "complete") ++ Run.list(status: "failed")

    (Enum.sort_by(live, & &1.started_at, {:desc, DateTime}) ++
       Enum.sort_by(finished, & &1.started_at, {:desc, DateTime}))
    |> Enum.take(limit)
  end

  @doc """
  A run as a stage checklist, including persisted successful node results.

  For failed runs, the recorded stopping stage is `:failed` and later stages
  are `:not_run`. The saved error belongs to that stopping stage, not to a
  node inferred from error prose. A missing catalog entry or cursor yields
  one `:unavailable` entry retaining the error and every saved node result.

  New runs use their persisted ordered definition. Legacy runs without a
  snapshot use the current catalog and cannot detect historical reordering.
  """
  def checklist(%{definition_snapshot: %{"stages" => stages}} = run) do
    definition = %{stages: Enum.map(stages, &%{name: &1["name"], per_item: &1["per_item"]})}
    checklist_for(run, definition)
  end

  def checklist(run) do
    case Catalog.fetch(run.workflow) do
      :error -> unavailable_checklist(run, :workflow_unavailable)
      {:ok, definition} -> checklist_for(run, definition)
    end
  end

  defp checklist_for(run, definition) do
    cursor = cursor_index(definition, run.stage)

    case {run.status, cursor} do
      {"failed", :done} ->
        unavailable_checklist(run, :stage_unavailable)

      _ ->
        results = Results.for_run(run.run_id)

        definition.stages
        |> Enum.with_index()
        |> Enum.map(fn {stage, index} ->
          state = stage_state(index, cursor, run.status)

          %{
            name: stage.name,
            per_item: stage.per_item,
            state: state,
            nodes: Enum.filter(results, &(&1.stage == to_string(stage.name))),
            error: if(state == :failed, do: run.error)
          }
        end)
    end
  end

  defp unavailable_checklist(%{status: "failed"} = run, reason) do
    [
      %{
        name: run.stage,
        per_item: false,
        state: :unavailable,
        nodes: Results.for_run(run.run_id),
        error: run.error,
        unavailable_reason: reason
      }
    ]
  end

  defp unavailable_checklist(_run, _reason), do: []

  @doc "What a run has spent, and against what rail (nil rail = unbounded)."
  def spend(run), do: %{spent_usd: Run.spent(run.run_id), budget_usd: run.budget_usd}

  @doc """
  Has this run reached its rail? A nil rail is unbounded -- what an iex
  launch gets, and what slice 1b's runs already are.

  The runner asks this before enqueueing, not after: spend is only knowable
  once a node has run, so the rail can only ever be enforced at the next
  barrier. It is a ceiling on what the run will START, not a guarantee about
  what it has finished.
  """
  def over_rail?(%{budget_usd: nil}), do: false

  def over_rail?(%{budget_usd: budget} = run) when is_number(budget),
    do: Run.spent(run.run_id) >= budget

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp find(proposal_id), do: Enum.find(pending(), &(&1["proposal"] == proposal_id))

  # The proposal carries the launch options forward so approving runs what was
  # priced, not what the defaults happen to be at approval time.
  defp launch_opts(opts) do
    %{
      "budget_usd" => Keyword.get(opts, :budget_usd) || default_budget(),
      "working_dir" => Keyword.get(opts, :working_dir),
      "max_budget_usd" => Keyword.get(opts, :max_budget_usd),
      "context" => Keyword.get(opts, :context, %{})
    }
  end

  defp launch_opts_of(entry) do
    stored = entry["estimate"] || %{}
    saved = entry["launch_opts"] || %{}

    [budget_usd: saved["budget_usd"] || stored["budget_usd"] || default_budget()]
    |> put_unless_nil(:working_dir, saved["working_dir"])
    |> put_unless_nil(:max_budget_usd, saved["max_budget_usd"])
    |> put_unless_nil(:context, saved["context"])
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  # The repo's observed per-turn cost: every agent the roster points at this
  # repo, plus the workflow runs already booked against it. With no history at
  # all the per-node CAP stands in, flagged as a default so the card can say
  # it is a ceiling.
  defp per_node_cost(repo) do
    case SpendLedger.mean_turn_cost(spenders(repo)) do
      nil -> {per_node_cap(), :default, 0}
      {mean, sample} -> {mean, :observed, sample}
    end
  end

  defp spenders(repo) do
    repo = to_string(repo)

    routines =
      Custode.Routine.all()
      |> Enum.filter(&(Map.get(&1, :repo) == repo))
      |> Enum.map(& &1.id)

    runs =
      from(r in Run.Row, where: r.repo == ^repo, select: r.run_id)
      |> Repo.all()
      |> Enum.map(&Run.spend_agent_id/1)

    routines ++ runs
  end

  defp cursor_index(_definition, nil), do: :done

  defp cursor_index(definition, stage) do
    Enum.find_index(definition.stages, &(to_string(&1.name) == to_string(stage))) || :done
  end

  defp stage_state(_index, :done, _status), do: :done
  defp stage_state(index, cursor, _status) when index < cursor, do: :done
  defp stage_state(index, cursor, "running") when index == cursor, do: :running
  defp stage_state(index, cursor, "failed") when index == cursor, do: :failed
  defp stage_state(_index, _cursor, "failed"), do: :not_run
  defp stage_state(index, cursor, _status) when index == cursor, do: :pending
  defp stage_state(_index, _cursor, _status), do: :pending

  defp summary(proposal) do
    count =
      if proposal.fans_out,
        do: "at least #{proposal.known_nodes} nodes",
        else: "#{proposal.known_nodes} nodes"

    price =
      case proposal.basis do
        :observed -> "~$#{fmt(proposal.floor_usd)} (#{proposal.sample} observed turns)"
        :default -> "up to $#{fmt(proposal.floor_usd)} (no history; the per-node cap)"
      end

    "run #{proposal.workflow} on #{proposal.repo}: #{count}, #{price}, " <>
      "rail $#{fmt(proposal.budget_usd)}"
  end

  defp fmt(:keep), do: "unchanged"
  defp fmt(nil), do: "none"
  defp fmt(usd) when is_number(usd), do: :erlang.float_to_binary(usd / 1, decimals: 2)

  defp mint_id do
    stamp = DateTime.utc_now() |> DateTime.to_unix()
    "wfl-#{stamp}-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end

  defp per_node_cap, do: Application.fetch_env!(:custode, :max_budget_usd)

  defp default_budget,
    do: Application.get_env(:custode, :workflow_budget_usd, 10.0 * per_node_cap())
end
