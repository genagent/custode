defmodule CustodeWeb.WorkflowsLive do
  @moduledoc """
  The workflows page (#271, design/005 slice 2): the launch gates waiting on a
  decision, and the runs those decisions produced.

  Two surfaces, in the order the operator needs them:

    * **launch gates** -- one card per standing proposal, carrying the
      workflow, the repo, the node count, and the spend estimate, with approve
      and reject. This is the only path to a run; design/005 is explicit that
      the button (slice 3) and the agent suggestion (slice 4) both arrive at
      this same gate rather than starting anything themselves.
    * **runs** -- one stage-checklist card each, the shape the Research
      pattern's checklist established: every stage of the definition, ticked
      as its barrier clears, with the nodes that landed under it. A run that
      hit its rail shows what it did NOT run and the button to let it go on.

  Everything is derived: the checklist comes from the persisted node results,
  the spend from the ledger. No page-local state to fall out of date.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Results

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("approve_launch", %{"id" => id}, socket) do
    case Launch.approve(id) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "launched #{run.workflow} -- run #{run.run_id}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "launch refused: #{inspect(reason)}")}
    end
  end

  def handle_event("reject_launch", %{"id" => id}, socket) do
    Launch.reject(id)
    {:noreply, socket |> put_flash(:info, "launch rejected") |> refresh()}
  end

  # Letting a parked run go on is a rail RAISE, not a rail removal. By how
  # much is `Launch.raise_and_resume/1`'s to say, since the inbox offers the
  # same button (#447).
  def handle_event("resume_run", %{"id" => id}, socket) do
    case Launch.raise_and_resume(id) do
      {:ok, _run} ->
        {:noreply, socket |> put_flash(:info, "run #{id} resumed") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "resume refused: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:workflows} launch_gates={length(@pending)}>
      <section :if={@pending != []} class="mb-8">
        <h3 class="mb-2 text-lg font-semibold text-base-content/70">
          launch gates ({length(@pending)})
        </h3>
        <div class="grid gap-3 md:grid-cols-2">
          <.launch_card :for={proposal <- @pending} proposal={proposal} />
        </div>
      </section>

      <h3 class="mb-2 text-lg font-semibold text-base-content/70">runs</h3>
      <p :if={@runs == []} class="text-sm text-base-content/40">
        no workflow runs yet -- a run starts at a launch gate, never anywhere else
      </p>
      <div class="space-y-3">
        <.run_card :for={entry <- @runs} entry={entry} />
      </div>

      <p :if={@pending == [] && @runs == []} class="mt-6 text-xs text-base-content/40">
        catalog: {Enum.join(@catalog, ", ")}
      </p>
    </.page>
    """
  end

  attr(:proposal, :map, required: true)

  # The gate card design/005 point 1 specifies: name, repo, node count, spend
  # estimate. The estimate says what it does NOT know -- a fan-out has no
  # knowable node count before its merge stage, and a repo with no ledger
  # history has no observed cost -- rather than quoting a confident total.
  defp launch_card(assigns) do
    assigns = assign(assigns, :estimate, assigns.proposal["estimate"] || %{})

    ~H"""
    <div class="card border border-warning/40 bg-base-100 shadow">
      <div class="card-body gap-2 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <span class="badge badge-warning badge-sm">launch gate</span>
          <span class="font-mono font-bold">{@proposal["workflow"]}</span>
          <span class="font-mono text-xs text-base-content/60">{@proposal["repo"]}</span>
          <span class="ml-auto font-mono text-xs text-base-content/50">
            <.ago at={@proposal["at"]} />
          </span>
        </div>
        <p :if={@proposal["why"]} class="text-sm text-base-content/70">{@proposal["why"]}</p>
        <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
          <dt class="text-base-content/50">nodes</dt>
          <dd class="text-right font-mono">
            {@estimate["known_nodes"]}<span :if={@estimate["fans_out"]}>+ (fans out)</span>
          </dd>
          <dt class="text-base-content/50">per node</dt>
          <dd class="text-right font-mono">
            ${usd(@estimate["per_node_usd"])}
            <span class="text-base-content/40">
              {basis(@estimate)}
            </span>
          </dd>
          <dt class="text-base-content/50">estimate</dt>
          <dd class="text-right font-mono">
            <span :if={@estimate["fans_out"]}>&ge; </span>${usd(@estimate["floor_usd"])}
          </dd>
          <dt class="text-base-content/50">run rail</dt>
          <dd class="text-right font-mono">${usd(@estimate["budget_usd"])}</dd>
        </dl>
        <p :if={@estimate["fans_out"]} class="text-xs text-base-content/40">
          a fan-out stage expands over items the merge has not produced yet, so the
          total is not knowable before the run. The rail is what bounds it.
        </p>
        <div class="card-actions justify-end">
          <button
            class="btn btn-ghost btn-sm"
            phx-click="reject_launch"
            phx-value-id={@proposal["proposal"]}
          >
            reject
          </button>
          <button
            class="btn btn-success btn-sm"
            phx-click="approve_launch"
            phx-value-id={@proposal["proposal"]}
            data-confirm={"Launch #{@proposal["workflow"]} on #{@proposal["repo"]}?"}
          >
            approve
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)

  # The stage checklist (design/005 point 6). One line per stage of the
  # definition -- not per stage that happened -- so a run parked halfway shows
  # the stages it never reached instead of ending where it stopped.
  defp run_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body gap-2 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <span class={["badge badge-sm", run_badge(@entry.run.status)]}>
            {@entry.run.status}
          </span>
          <span class="font-mono font-bold">{@entry.run.workflow}</span>
          <span class="font-mono text-xs text-base-content/60">{@entry.run.repo}</span>
          <span class="font-mono text-xs text-base-content/40">{@entry.run.run_id}</span>
          <span class="ml-auto font-mono text-xs">
            ${usd(@entry.spend.spent_usd)}<span
              :if={@entry.spend.budget_usd}
              class="text-base-content/50"
            > / ${usd(@entry.spend.budget_usd)}</span>
          </span>
        </div>

        <ol class="flex flex-col gap-1">
          <li :for={stage <- @entry.checklist} class="flex items-baseline gap-2 text-sm">
            <span class={["font-mono text-xs", stage_class(stage.state)]}>{mark(stage.state)}</span>
            <span class={["font-mono", stage.state == :pending && "text-base-content/40"]}>
              {stage.name}
            </span>
            <span :if={stage.per_item} class="badge badge-ghost badge-xs">per item</span>
            <span :if={stage.nodes != []} class="text-xs text-base-content/50">
              {Enum.map_join(stage.nodes, ", ", & &1.node_name)}
            </span>
          </li>
        </ol>

        <p :if={@entry.run.error} class="text-xs text-error">{@entry.run.error}</p>

        <div :if={@entry.artifacts != []} class="rounded bg-base-200/60 p-2">
          <span class="text-xs uppercase tracking-wide text-base-content/40">report</span>
          <ul class="font-mono text-xs text-base-content/70">
            <li :for={artifact <- @entry.artifacts}>{artifact}</li>
          </ul>
        </div>

        <div :if={@entry.run.notes != []} class="rounded bg-base-200/60 p-2">
          <span class="text-xs uppercase tracking-wide text-base-content/40">
            what it did not do
          </span>
          <ul class="list-inside list-disc text-xs text-base-content/70">
            <li :for={note <- @entry.run.notes}>{note}</li>
          </ul>
        </div>

        <div :if={@entry.run.status == "budget_paused"} class="card-actions justify-end">
          <button
            class="btn btn-warning btn-sm"
            phx-click="resume_run"
            phx-value-id={@entry.run.run_id}
            data-confirm="Double this run's rail and let it go on?"
          >
            raise the rail and resume
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp basis(%{"basis" => "observed", "sample" => sample}), do: "observed over #{sample} turns"
  defp basis(%{"basis" => "default"}), do: "the per-node cap (no history)"
  defp basis(_estimate), do: ""

  defp mark(:done), do: "[x]"
  defp mark(:running), do: "[~]"
  defp mark(:pending), do: "[ ]"

  defp stage_class(:done), do: "text-success"
  defp stage_class(:running), do: "text-info"
  defp stage_class(:pending), do: "text-base-content/30"

  defp run_badge("running"), do: "badge-info"
  defp run_badge("complete"), do: "badge-success"
  defp run_badge("failed"), do: "badge-error"
  defp run_badge("budget_paused"), do: "badge-warning"
  defp run_badge(_status), do: "badge-ghost"

  defp refresh(socket) do
    runs =
      for run <- Launch.recent() do
        %{
          run: run,
          checklist: Launch.checklist(run),
          spend: Launch.spend(run),
          # a deep-report run's whole output is a file; a card that shows the
          # stages green and nothing else leaves the operator hunting for it
          artifacts: Results.artifacts(run.run_id)
        }
      end

    assign(socket,
      fleet_today: Custode.SpendLedger.fleet_today(),
      pending: Launch.pending(),
      runs: runs,
      catalog: Catalog.names()
    )
  end
end
