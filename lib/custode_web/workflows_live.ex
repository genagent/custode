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

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  alias Custode.Operator.Actions
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Results
  alias Custode.Workflow.RetryStatus

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl Phoenix.LiveView
  def handle_event("approve_launch", %{"id" => id}, socket) do
    case Actions.approve_launch(id, via: :liveview) do
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
    Actions.reject_launch(id, "rejected from the dashboard", via: :liveview)
    {:noreply, socket |> put_flash(:info, "launch rejected") |> refresh()}
  end

  # Letting a parked run go on is a rail RAISE, not a rail removal. By how
  # much is `Launch.raise_and_resume/1`'s to say, since the inbox offers the
  # same button (#447).
  def handle_event("resume_run", %{"id" => id}, socket) do
    case Actions.resume_run(id, via: :liveview) do
      {:ok, _run} ->
        {:noreply, socket |> put_flash(:info, "run #{id} resumed") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "resume refused: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:workflows} launch_gates={length(@pending)}>
      <.page_header
        title="Workflows"
        summary={"#{length(@pending)} pending #{if length(@pending) == 1, do: "launch", else: "launches"} · #{length(@runs)} recent #{if length(@runs) == 1, do: "run", else: "runs"}"}
      />
      <section :if={@pending != []} class="mb-8">
        <h2 class="mb-2 text-lg font-semibold text-base-content/70">
          Launch gates ({length(@pending)})
        </h2>
        <div role="list" aria-label="Launch gates" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
          <.launch_card :for={proposal <- @pending} proposal={proposal} />
        </div>
      </section>

      <h2 class="mb-2 text-lg font-semibold text-base-content/70">Runs</h2>
      <p :if={@runs == []} class="text-sm text-base-content/40">
        no workflow runs yet -- a run starts at a launch gate, never anywhere else
      </p>
      <div :if={@runs != []} role="list" aria-label="Workflow runs" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
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
    <section role="listitem" class="p-4">
      <div class="flex min-w-0 flex-col gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <.status_token tone={:warning}>launch gate</.status_token>
          <span class="font-mono font-bold [overflow-wrap:anywhere]">{@proposal["workflow"]}</span>
          <span class="font-mono text-xs text-base-content/60 [overflow-wrap:anywhere]">{@proposal["repo"]}</span>
          <span class="ml-auto tabular-nums text-xs text-base-content/50">
            <.ago at={@proposal["at"]} />
          </span>
        </div>
        <p :if={@proposal["why"]} class="text-sm text-base-content/70">{@proposal["why"]}</p>
        <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
          <dt class="text-base-content/50">nodes</dt>
          <dd class="text-right tabular-nums">
            {@estimate["known_nodes"]}<span :if={@estimate["fans_out"]}>+ (fans out)</span>
          </dd>
          <dt class="text-base-content/50">per node</dt>
          <dd class="text-right tabular-nums">
            ${usd(@estimate["per_node_usd"])}
            <span class="text-base-content/40">
              {basis(@estimate)}
            </span>
          </dd>
          <dt class="text-base-content/50">estimate</dt>
          <dd class="text-right tabular-nums">
            <span :if={@estimate["fans_out"]}>&ge; </span>${usd(@estimate["floor_usd"])}
          </dd>
          <dt class="text-base-content/50">run rail</dt>
          <dd class="text-right tabular-nums">${usd(@estimate["budget_usd"])}</dd>
        </dl>
        <p :if={@estimate["fans_out"]} class="text-xs text-base-content/40">
          a fan-out stage expands over items the merge has not produced yet, so the
          total is not knowable before the run. The rail is what bounds it.
        </p>
        <div class="card-actions justify-end">
          <.action_button
            variant={:quiet}
            phx-click="reject_launch"
            phx-value-id={@proposal["proposal"]}
          >
            Reject
          </.action_button>
          <.action_button
            variant={:primary}
            phx-click="approve_launch"
            phx-value-id={@proposal["proposal"]}
            data-confirm={"Launch #{@proposal["workflow"]} on #{@proposal["repo"]}?"}
          >
            Approve
          </.action_button>
        </div>
      </div>
    </section>
    """
  end

  attr(:entry, :map, required: true)

  # The stage checklist (design/005 point 6). One line per stage of the
  # definition -- not per stage that happened -- so a run parked halfway shows
  # the stages it never reached instead of ending where it stopped.
  defp run_card(assigns) do
    ~H"""
    <section role="listitem" data-workflow-run={@entry.run.run_id} class="p-4">
      <div class="flex min-w-0 flex-col gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <.status_token tone={run_tone(@entry.run.status)} running={@entry.run.status == "running"}>
            {@entry.run.status}
          </.status_token>
          <span class="font-mono font-bold [overflow-wrap:anywhere]">{@entry.run.workflow}</span>
          <span class="font-mono text-xs text-base-content/60 [overflow-wrap:anywhere]">{@entry.run.repo}</span>
          <span class="font-mono text-xs text-base-content/40 [overflow-wrap:anywhere]">{@entry.run.run_id}</span>
          <span class="ml-auto tabular-nums text-xs">
            ${usd(@entry.spend.spent_usd)}<span
              :if={@entry.spend.budget_usd}
              class="text-base-content/50"
            > / ${usd(@entry.spend.budget_usd)}</span>
          </span>
        </div>

        <ol class="flex flex-col gap-2">
          <li
            :for={stage <- @entry.checklist}
            data-workflow-stage={stage.name}
            data-stage-state={stage.state}
            class="min-w-0 text-sm"
          >
            <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <span aria-hidden="true" class={["font-mono text-xs", stage_class(stage.state)]}>
                {mark(stage.state)}
              </span>
              <span
                :if={stage.state != :unavailable}
                class={[
                  "font-mono [overflow-wrap:anywhere]",
                  stage.state in [:pending, :not_run] && "text-base-content/40"
                ]}
              >
                {stage.name}
              </span>
              <span :if={stage.state == :unavailable} class="text-error">
                Recorded stopping stage unavailable
              </span>
              <span
                :if={stage.state in [:failed, :not_run]}
                class={["text-xs", stage_class(stage.state)]}
              >
                {stage_label(stage.state)}
              </span>
              <span :if={stage.state in [:done, :running, :pending]} class="sr-only">
                {stage_label(stage.state)}
              </span>
              <span :if={stage.per_item} class="badge badge-ghost badge-xs">per item</span>
              <span
                :if={stage.nodes != []}
                class="text-xs text-base-content/60 [overflow-wrap:anywhere]"
              >
                <span :if={stage.state == :unavailable}>Recorded successful nodes: </span>
                {Enum.map_join(stage.nodes, ", ", & &1.node_name)}
              </span>
            </div>
            <p :if={stage.state == :unavailable} class="mt-1 text-xs text-base-content/70">
              {unavailable_reason(stage.unavailable_reason)}
              <span :if={stage.name} class="[overflow-wrap:anywhere]">
                Recorded stage: <span class="font-mono">{stage.name}</span>.
              </span>
            </p>
            <.foldable_text
              :if={Map.get(stage, :error)}
              text={stage.error}
              class="mt-1 min-w-0 text-xs text-error [overflow-wrap:anywhere]"
            />
          </li>
        </ol>

        <p :if={@entry.run.status == "failed"} class="text-xs text-base-content/60">
          Retry is unavailable: Custode cannot yet prove earlier agents stopped or that repeating this stage would avoid duplicate changes.
        </p>
        <details :if={@entry.run.status == "failed"} data-workflow-retry-status={@entry.run.run_id}>
          <summary class="cursor-pointer text-xs">Why retry is unavailable</summary>
          <p class="text-xs text-base-content/70">Saved results: {@entry.retry_status.result_validation.schema_validated} validated against their declared structure; {@entry.retry_status.result_validation.legacy_or_unbound} without bound validation. This does not make a retry safe.</p>
          <p :if={@entry.retry_status.result_validation.truncated} class="text-xs text-base-content/70">Showing the first 100 result bindings.</p>
          <ul class="list-disc pl-4 text-xs text-base-content/70"><li :for={reason <- @entry.retry_status.reasons}>{reason.message}</li></ul>
        </details>
        <p :if={@entry.run.error && @entry.run.status != "failed"} class="text-xs text-error">
          {@entry.run.error}
        </p>

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
          <.action_button
            variant={:primary}
            phx-click="resume_run"
            phx-value-id={@entry.run.run_id}
            data-confirm="Double this run's rail and let it go on?"
          >
            Raise the rail and resume
          </.action_button>
        </div>
      </div>
    </section>
    """
  end

  defp basis(%{"basis" => "observed", "sample" => sample}),
    do: "observed over #{sample} #{if sample == 1, do: "turn", else: "turns"}"

  defp basis(%{"basis" => "default"}), do: "the per-node cap (no history)"
  defp basis(_estimate), do: ""

  defp mark(:done), do: "[x]"
  defp mark(:running), do: "[~]"
  defp mark(:pending), do: "[ ]"
  defp mark(:failed), do: "[!]"
  defp mark(:not_run), do: "[-]"
  defp mark(:unavailable), do: "[?]"

  defp stage_label(:done), do: "Done"
  defp stage_label(:running), do: "Running"
  defp stage_label(:pending), do: "Pending"
  defp stage_label(:failed), do: "Failed"
  defp stage_label(:not_run), do: "Not run"

  defp unavailable_reason(:workflow_unavailable),
    do: "This workflow is no longer in the catalog. Stage positions cannot be determined."

  defp unavailable_reason(:stage_unavailable),
    do: "The saved stopping point does not identify a stage in the current definition."

  defp stage_class(:done), do: "text-success"
  defp stage_class(:running), do: "text-info"
  defp stage_class(:pending), do: "text-base-content/30"
  defp stage_class(:failed), do: "text-error"
  defp stage_class(:not_run), do: "text-base-content/50"
  defp stage_class(:unavailable), do: "text-error"

  defp run_tone("running"), do: :info
  defp run_tone("complete"), do: :success
  defp run_tone("failed"), do: :error
  defp run_tone("budget_paused"), do: :warning
  defp run_tone(_status), do: :neutral

  defp retry_status(id) do
    case RetryStatus.read(%{kind: :operator, id: "dashboard"}, id) do
      {:ok, status} -> status
      {:error, _reason} -> %{reasons: [%{message: "Retry readiness is unavailable."}]}
    end
  end

  defp refresh(socket) do
    socket = AttentionSnapshot.refresh(socket)

    runs =
      for run <- Launch.recent() do
        %{
          run: run,
          checklist: Launch.checklist(run),
          spend: Launch.spend(run),
          # a deep-report run's whole output is a file; a card that shows the
          # stages green and nothing else leaves the operator hunting for it
          artifacts: Results.artifacts(run.run_id),
          retry_status: if(run.status == "failed", do: retry_status(run.run_id), else: nil)
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
