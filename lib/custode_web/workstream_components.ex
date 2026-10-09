defmodule CustodeWeb.WorkstreamComponents do
  @moduledoc "Compact workstream views with attributed records and separate execution facts."

  use Phoenix.Component

  import CustodeWeb.Components,
    only: [
      ago: 1,
      foldable_text: 1,
      interval_report: 1,
      page_header: 1,
      status_token: 1,
      until_text: 1
    ]

  alias CustodeWeb.Console.Rail

  attr(:dashboard, :map, required: true)

  def home(assigns) do
    ~H"""
    <section id="workstream-home">
      <.page_header title="Workstreams" summary="Purpose, reported progress and current observations.">
        <:action><.link navigate={@dashboard.links.manager} class="btn btn-primary btn-sm">PM conversation</.link></:action>
      </.page_header>
      <.attention signals={@dashboard.attention} />
      <p :if={@dashboard.workstreams == []} id="workstreams-empty" class="rounded-box border border-base-300 p-5 text-base-content/70">
        No configured workstreams. <.link navigate={@dashboard.links.control_room} class="link">Open Console</.link> to inspect the fleet.
      </p>
      <div class="grid min-w-0 gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.workstream_card :for={workstream <- @dashboard.workstreams} workstream={workstream} />
      </div>
      <.coverage dashboard={@dashboard} />
    </section>
    """
  end

  attr(:signals, :list, required: true)

  defp attention(assigns) do
    ~H"""
    <section id="workstream-attention" aria-labelledby="workstream-attention-title" class="mb-6 rounded-box border border-base-300 bg-base-100 p-4">
      <div class="flex flex-wrap items-baseline gap-3">
        <h2 id="workstream-attention-title" class="font-semibold">Attention <span class="text-base-content/60">· {length(@signals)}</span></h2>
        <.link navigate="/inbox" class="link ml-auto text-sm">Open Inbox</.link>
      </div>
      <p :if={@signals == []} class="mt-2 text-sm text-base-content/60">Nothing currently needs you in the shared attention view.</p>
      <ol :if={@signals != []} class="mt-2 space-y-2 text-sm">
        <li :for={signal <- Enum.take(@signals, 5)}>
          <.attention_link signal={signal} />
        </li>
      </ol>
      <details :if={length(@signals) > 5} id="workstream-attention-more" phx-hook="DisclosureState" class="mt-3">
        <summary class="cursor-pointer text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2">{length(@signals) - 5} more ranked attention items</summary>
        <ol start="6" class="mt-2 space-y-2 text-sm">
          <li :for={signal <- Enum.drop(@signals, 5)}><.attention_link signal={signal} /></li>
        </ol>
      </details>
      <p class="mt-3 text-xs text-base-content/60">The same ranked records shown in Inbox and Console.</p>
    </section>
    """
  end

  attr(:signal, :map, required: true)

  defp attention_link(assigns) do
    ~H"""
    <.link navigate={Rail.subject_path(@signal.subject)} class="link break-words">
      <span class="font-mono">{@signal.subject}</span> · {@signal.headline}
    </.link>
    <.foldable_text
      :if={@signal.detail}
      text={@signal.detail}
      id={"workstream-attention-detail-#{URI.encode(@signal.subject, &URI.char_unreserved?/1)}"}
      class="mt-1 text-sm text-base-content/70"
    />
    """
  end

  attr(:workstream, :map, required: true)

  defp workstream_card(assigns) do
    assigns = assign(assigns, :latest, List.first(assigns.workstream.digest.reports))

    ~H"""
    <article id={"workstream-#{@workstream.id}"} data-workstream-owner={@workstream.id} class="card min-w-0 border border-base-300 bg-base-100">
      <div class="card-body gap-3 p-4">
        <div class="flex flex-wrap items-start gap-2">
          <h2 class="min-w-0 flex-1 break-words font-mono font-semibold"><.link patch={@workstream.links.detail} class="link">{@workstream.id}</.link></h2>
          <.state state={@workstream.state} />
        </div>
        <p :if={@workstream.repo} class="break-all text-xs text-base-content/60">{@workstream.repo}</p>
        <div class="min-w-0 overflow-x-auto [overflow-wrap:anywhere]">
          <h3 class="mb-1 text-xs font-semibold text-base-content/70">Purpose</h3>
          <p :if={@workstream.purpose.entries == []} class="text-sm text-base-content/60">No purpose recorded in the shown agreements.</p>
          <.foldable_text :for={purpose <- Enum.take(@workstream.purpose.entries, 1)} text={purpose.text} markdown id={"workstream-purpose-#{@workstream.id}"} class="text-sm" />
          <p :if={length(@workstream.purpose.entries) > 1} class="mt-1 text-xs text-base-content/60">{length(@workstream.purpose.entries)} recorded purposes in shown agreements; open the workstream for details.</p>
          <p :if={@workstream.agreements["has_more"]} class="mt-1 text-xs text-base-content/60">Older agreements are outside this view and may still contain open work.</p>
        </div>
        <div class="min-w-0 overflow-x-auto [overflow-wrap:anywhere]">
          <h3 class="mb-1 text-xs font-semibold text-base-content/70">Latest reported summary in this view</h3>
          <.foldable_text :if={@latest} text={@latest.summary || "Recorded update without a summary."} markdown id={"workstream-summary-#{@workstream.id}"} class="text-sm" />
          <p :if={!@latest} class="text-sm text-base-content/60">No retained report in this window. This does not establish inactivity.</p>
        </div>
        <div class="mt-auto space-y-1 border-t border-base-300 pt-3 text-xs text-base-content/60">
          <.freshness workstream={@workstream} />
          <.next_check at={@workstream.next_beat_at} />
        </div>
        <.link patch={@workstream.links.detail} class="link self-start text-sm">Open workstream <span class="sr-only">{@workstream.id}</span></.link>
      </div>
    </article>
    """
  end

  attr(:state, :map, required: true)

  defp state(assigns) do
    ~H"""
    <span :if={@state.tone == :neutral} class="text-xs text-base-content/60" title={@state.detail}>{@state.label}</span>
    <.status_token :if={@state.tone != :neutral} tone={@state.tone} title={@state.detail}>{@state.label}</.status_token>
    """
  end

  attr(:workstream, :map, required: true)

  defp freshness(assigns) do
    ~H"""
    <p>
      Agent report: {@workstream.digest.freshness.state}
      <span :if={@workstream.digest.freshness.latest_recorded_at}> · last recorded <.ago at={@workstream.digest.freshness.latest_recorded_at} /></span>
    </p>
    <p :if={@workstream.digest.freshness.state == "stale"}>Older than {@workstream.digest.freshness.stale_after_hours} hours; current progress is not established by this report.</p>
    """
  end

  attr(:at, :any, default: nil)

  defp next_check(assigns) do
    ~H"""
    <p :if={@at}>Next scheduled check <time datetime={DateTime.to_iso8601(@at)} title={DateTime.to_iso8601(@at)}>{next_check_text(@at)}</time></p>
    <p :if={!@at}>Next scheduled check unavailable.</p>
    """
  end

  attr(:workstream, :map, required: true)
  attr(:dashboard, :map, required: true)

  def detail(assigns) do
    agreements = assigns.workstream.agreements["agreements"]
    active = Enum.reject(agreements, &(&1["current"]["status"] in ["accepted", "rejected"]))

    assigns =
      assigns
      |> assign(:agreements, agreements)
      |> assign(:active_agreements, active)
      |> assign(:submissions, Enum.filter(agreements, & &1["current"]["submission"]))
      |> assign(:steps, checkpoint_entries(active, "next_steps"))
      |> assign(:decisions, checkpoint_entries(active, "decisions"))
      |> assign(:blockers, checkpoint_entries(active, "blockers"))
      |> assign(
        :open_decisions,
        assigns.workstream.digest.decisions.gates ++ assigns.workstream.digest.decisions.asks
      )
      |> assign(:reported_decisions, concerns(assigns.workstream, :decisions))
      |> assign(:reported_blockers, concerns(assigns.workstream, :blockers))

    ~H"""
    <article id="workstream-detail" data-workstream-owner={@workstream.id} class="mx-auto max-w-5xl min-w-0">
      <.link patch="/" class="link mb-4 inline-block text-sm">All workstreams</.link>
      <.page_header title={@workstream.id} summary={@workstream.repo || "Configured workstream"}>
        <:action>
          <.link navigate={@workstream.links.conversation} class="btn btn-primary btn-sm">Talk to owner</.link>
          <.link navigate={@dashboard.links.manager} class="btn btn-outline btn-sm">PM conversation</.link>
        </:action>
      </.page_header>
      <.agreement_page page={@workstream.agreement_page} />
      <div class="mb-5 space-y-2 text-sm">
        <.state state={@workstream.state} />
        <p class="text-base-content/70">{@workstream.state.detail}</p>
        <.freshness workstream={@workstream} />
        <.next_check at={@workstream.next_beat_at} />
        <p class="text-xs text-base-content/60">Observed <.ago at={@dashboard.observed_at} />. Sources are read independently.</p>
        <div :if={@workstream.signal && Custode.Signal.needs_you?(@workstream.signal)}><.attention_link signal={@workstream.signal} /></div>
      </div>
      <div class="space-y-3">
        <.section id="workstream-purpose" title="Purpose" count={length(@agreements)} open>
          <p :if={@agreements == []} class="text-base-content/60">No intended outcome or standing remit recorded in the shown agreements.</p>
          <div :for={agreement <- @agreements} class="space-y-2 border-b border-base-300 pb-3 last:border-0 last:pb-0">
            <.foldable_text text={agreement["current"]["intent"]["outcome"]} markdown id={"purpose-#{agreement["agreement_id"]}"} />
            <.agreement_source agreement={agreement} record={agreement["current"]["intent_record"]} />
            <details id={"criteria-#{agreement["agreement_id"]}"} phx-hook="DisclosureState">
              <summary class="cursor-pointer text-xs">Criteria, boundaries and source references</summary>
              <ul class="mt-2 list-disc space-y-2 pl-5">
                <li :for={criterion <- agreement["current"]["intent"]["criteria"]}><.foldable_text text={criterion["text"]} markdown id={"criterion-#{agreement["agreement_id"]}-#{URI.encode(criterion["id"], &URI.char_unreserved?/1)}"} /></li>
                <li :for={{boundary, index} <- Enum.with_index(agreement["current"]["intent"]["boundaries"])}><.foldable_text text={boundary} markdown id={"boundary-#{agreement["agreement_id"]}-#{index}"} /></li>
              </ul>
              <.references entries={agreement["current"]["intent"]["request_references"] ++ agreement["current"]["intent"]["inputs"] ++ agreement["current"]["intent"]["expected_outputs"]} />
            </details>
          </div>
        </.section>
        <.section id="workstream-done" title="Done">
          <p class="text-xs text-base-content/60">Reports and submissions are attributed claims. Accepted records record a review decision; neither acceptance nor a report's Verified entries establish independent verification.</p>
          <p :if={@submissions == [] && @workstream.digest.reports == []} class="text-base-content/60">No submission or reported outcome in this view.</p>
          <.submission :for={agreement <- @submissions} agreement={agreement} />
          <div :for={report <- @workstream.digest.reports} class="space-y-2 border-t border-base-300 pt-3">
            <p class="text-xs text-base-content/60">Agent report · <.ago at={report.recorded_at} /><span :if={report.event == "turn_failed"}> · recorded failed turn</span></p>
            <.foldable_text text={report.summary || "Recorded update without a summary."} markdown id={"done-summary-#{report.id}"} />
            <.reported_lines title="Reported done" entries={report_entries(report, "done")} id={"done-#{report.id}"} />
            <.reported_lines title="Reported checks (Verified claims)" entries={report_entries(report, "verified")} id={"verified-#{report.id}"} />
            <p :if={report.report_error} class="text-xs text-base-content/60">Typed report unavailable: {report.report_error}</p>
          </div>
        </.section>
        <.section id="workstream-doing" title="Doing" count={length(@active_agreements)} open>
          <p class="text-xs text-base-content/60">Recorded assignments and actual execution are separate observations. A running process alone does not identify the assignment being worked.</p>
          <p :if={@active_agreements == []} class="text-base-content/60">No current assignment recorded in the shown open agreements.</p>
          <div :for={agreement <- @active_agreements} class="space-y-2 border-t border-base-300 pt-3">
            <p>Owner <span class="font-mono">{agreement["owner_id"]}</span> · assignment <span class="break-all font-mono">{agreement["current"]["intent"]["assignment_id"]}</span> · {agreement["current"]["status"]}</p>
            <.foldable_text text={agreement["current"]["intent"]["outcome"]} markdown id={"assignment-#{agreement["agreement_id"]}"} />
            <.foldable_text :if={agreement["current"]["checkpoint"]} text={agreement["current"]["checkpoint"]["payload"]["summary"]} markdown id={"checkpoint-#{agreement["agreement_id"]}"} />
            <.agreement_source agreement={agreement} record={agreement["current"]["checkpoint"] || agreement["current"]["intent_record"]} />
          </div>
          <div class="space-y-2 border-t border-base-300 pt-3">
            <h3 class="font-semibold">Observed execution</h3>
            <p :if={@workstream.execution.applied}>Live process: {@workstream.execution.applied.state || "state unknown"} · {@workstream.execution.applied.provider || "provider unknown"}.</p>
            <p :if={!@workstream.execution.applied && !@workstream.execution.live_error}>No live owner process observed. This does not establish inactivity.</p>
            <p :if={@workstream.execution.live_error}>Live process observation unavailable.</p>
            <p :if={@workstream.execution.active}>Correlated turn: job <span class="font-mono">{@workstream.execution.active.id}</span> · {@workstream.execution.active.provider} · {@workstream.execution.active.model || "model unknown"}.</p>
            <p :if={!@workstream.execution.active}>No correlated active turn observed.</p>
            <p class="text-xs text-base-content/60">A paused state does not confirm a process has physically stopped.</p>
          </div>
        </.section>
        <.section id="workstream-todo" title="Todo" count={length(@steps)}>
          <p class="text-xs text-base-content/60">Bounded next steps recorded in agreement checkpoints. Report Next prose is shown with report history and does not create a committed step.</p>
          <p :if={@steps == []} class="text-base-content/60">No committed next steps recorded in the shown agreement checkpoints.</p>
          <.checkpoint_entry :for={entry <- @steps} entry={entry} prefix="todo" />
        </.section>
        <.section id="workstream-decisions" title="Decisions" count={length(@open_decisions) + length(@decisions) + length(@reported_decisions)} open={@open_decisions != [] || @decisions != []}>
          <p :if={@open_decisions == [] && @decisions == [] && @reported_decisions == []} class="text-base-content/60">No open questions, gates or recorded decision requests in this view.</p>
          <div :for={decision <- @open_decisions} class="space-y-2 border-b border-base-300 pb-3 last:border-0">
            <p class="font-semibold">{if decision.blocking, do: "Open gate", else: "Open question"} #{decision.id}</p>
            <.foldable_text text={decision.text || "No detail recorded."} markdown id={"decision-#{decision.kind}-#{decision.id}"} />
            <p class="text-xs text-base-content/60">Current open record · opened <.ago at={decision.opened_at} /> · resolver: operator</p>
            <.link navigate={@workstream.links.control_room} class="link text-xs">Open in Console</.link>
          </div>
          <p :if={@workstream.digest.decisions.has_more_asks || @workstream.digest.decisions.has_more_gates} class="text-xs text-base-content/60">More open records are available in <.link navigate={@workstream.links.control_room} class="link">Console</.link>.</p>
          <.checkpoint_entry :for={entry <- @decisions} entry={entry} prefix="decision" />
          <.reported_concerns workstream={@workstream} entries={@reported_decisions} kind="decisions" />
        </.section>
        <.section id="workstream-blockers" title="Blockers" count={length(@blockers) + length(@reported_blockers)} open={@blockers != [] || @reported_blockers != []}>
          <p :if={@blockers == [] && @reported_blockers == []} class="text-base-content/60">No blockers recorded in the shown open agreements or latest typed report. This is not a claim that all work is unblocked.</p>
          <.checkpoint_entry :for={entry <- @blockers} entry={entry} prefix="blocker" />
          <.reported_concerns workstream={@workstream} entries={@reported_blockers} kind="blockers" />
        </.section>
        <.diagnostics workstream={@workstream} />
      </div>
      <.coverage dashboard={@dashboard} />
    </article>
    """
  end

  attr(:page, :map, required: true)

  defp agreement_page(assigns) do
    ~H"""
    <aside :if={@page.position == :older || @page.has_more} id="workstream-agreement-coverage" aria-labelledby="workstream-agreement-coverage-title" data-agreement-page={@page.position} class="mb-5 rounded-box border border-base-300 bg-base-200 p-4 text-sm">
      <p :if={@page.position == :newest} id="workstream-agreement-coverage-title" class="font-semibold">Limited agreement coverage</p>
      <p :if={@page.position == :newest} class="mt-1 text-base-content/70">Showing the newest {@page.shown} agreements. Older assignments, committed steps, decisions and blockers may still be open.</p>
      <p :if={@page.position == :older} id="workstream-agreement-coverage-title" class="font-semibold">Older agreements</p>
      <p :if={@page.position == :older} class="mt-1 text-base-content/70">
        Showing {@page.shown} older agreements.
        <span :if={@page.has_more}>Still older agreements may contain open work.</span>
        <span :if={!@page.has_more}>No older agreements are recorded for this owner.</span>
      </p>
      <p class="mt-1 text-xs text-base-content/60">Purpose, submissions, assignments, committed steps, recorded decisions and blockers cover this agreement page. Reports, open questions and gates, and observed execution remain current.</p>
      <nav aria-label="Agreement pages" class="mt-2 flex flex-wrap gap-4">
        <.link :if={@page.newest} patch={@page.newest} class="link">Newest agreements</.link>
        <.link :if={@page.older} patch={@page.older} class="link">Older agreements</.link>
      </nav>
    </aside>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:count, :integer, default: nil)
  attr(:open, :boolean, default: false)
  slot(:inner_block, required: true)

  defp section(assigns) do
    ~H"""
    <details id={@id} open={@open} phx-hook="DisclosureState" class="rounded-box border border-base-300 bg-base-100 p-4">
      <summary class="cursor-pointer font-semibold focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2">{@title} <span :if={!is_nil(@count)} class="font-normal text-base-content/60">· {@count} shown</span></summary>
      <div class="mt-3 min-w-0 space-y-3 break-words text-sm">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr(:agreement, :map, required: true)
  attr(:record, :map, required: true)

  defp agreement_source(assigns) do
    ~H"""
    <p class="break-words text-xs text-base-content/60">
      Work agreement <span class="font-mono">{@agreement["agreement_id"]}</span> · revision {@agreement["current_revision"]}
      · recorded by {@record["recorded_by"]["kind"]} <span class="font-mono">{@record["recorded_by"]["id"]}</span>
      · <.ago at={@record["recorded_at"]} />
    </p>
    """
  end

  attr(:agreement, :map, required: true)

  defp submission(assigns) do
    assigns = assign(assigns, :record, assigns.agreement["current"]["submission"])
    assigns = assign(assigns, :resolution, assigns.agreement["current"]["resolution"])

    ~H"""
    <div class="space-y-2 border-t border-base-300 pt-3">
      <h3 class="font-semibold">Submission · {String.replace(@agreement["current"]["status"], "_", " ")}</h3>
      <.foldable_text text={@record["payload"]["summary"]} markdown id={"submission-#{@record["record_id"]}"} />
      <.agreement_source agreement={@agreement} record={@record} />
      <p class="text-xs font-semibold">Verification limits</p>
      <.foldable_text text={@record["payload"]["verification_limits"]} markdown id={"limits-#{@record["record_id"]}"} />
      <div :if={@resolution} class="space-y-1">
        <p class="text-xs font-semibold">Review decision: {String.replace(@resolution["payload"]["outcome"], "_", " ")}</p>
        <.foldable_text text={@resolution["payload"]["reason"]} markdown id={"resolution-#{@resolution["record_id"]}"} />
        <.agreement_source agreement={@agreement} record={@resolution} />
      </div>
      <details id={"submission-evidence-#{@record["record_id"]}"} phx-hook="DisclosureState">
        <summary class="cursor-pointer text-xs">Criterion evidence and outputs</summary>
        <div :for={{evidence, index} <- Enum.with_index(@record["payload"]["criterion_evidence"])} class="mt-2 space-y-1">
          <p class="text-xs font-mono">{evidence["criterion_id"]}</p>
          <.foldable_text text={evidence["note"]} markdown id={"evidence-#{@record["record_id"]}-#{index}"} />
          <.references entries={evidence["references"]} />
        </div>
        <.references entries={@record["payload"]["outputs"]} />
      </details>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:prefix, :string, required: true)

  defp checkpoint_entry(assigns) do
    ~H"""
    <div class="space-y-2 border-t border-base-300 pt-3">
      <.foldable_text text={@entry.item["text"]} markdown id={"#{@prefix}-#{@entry.agreement["agreement_id"]}-#{URI.encode(@entry.item["id"], &URI.char_unreserved?/1)}"} />
      <p :if={@entry.item["resolver"]} class="text-xs">Recorded resolver: {@entry.item["resolver"]["kind"]} <span class="font-mono">{@entry.item["resolver"]["id"]}</span>. Resolution has not been independently established.</p>
      <.agreement_source agreement={@entry.agreement} record={@entry.record} />
      <.references entries={@entry.item["references"]} />
      <p :if={@entry.item["references"] == []} class="text-xs text-base-content/60">No dependency or evidence references recorded.</p>
    </div>
    """
  end

  attr(:workstream, :map, required: true)
  attr(:entries, :list, required: true)
  attr(:kind, :string, required: true)

  defp reported_concerns(assigns) do
    ~H"""
    <div :if={@entries != []} class="space-y-2 border-t border-base-300 pt-3">
      <p class="text-xs text-base-content/60">Agent-reported {@kind} · last recorded <.ago at={@workstream.digest.reported_concerns.recorded_at} /> · resolution, resolver and consequence are not independently established.</p>
      <.reported_lines title={"Reported #{@kind}"} entries={@entries} id={"reported-#{@kind}-#{@workstream.id}"} />
      <.link navigate={@workstream.links.conversation} class="link text-xs">Open source conversation</.link>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:id, :string, required: true)

  defp reported_lines(assigns) do
    ~H"""
    <div :if={@entries != []}>
      <h3 class="text-xs font-semibold">{@title}</h3>
      <ul class="mt-1 list-disc space-y-1 pl-5">
        <li :for={{text, index} <- Enum.with_index(@entries)}><.foldable_text text={text} markdown id={"#{@id}-#{index}"} /></li>
      </ul>
    </div>
    """
  end

  attr(:entries, :list, required: true)

  defp references(assigns) do
    ~H"""
    <ul :if={@entries != []} class="space-y-1 text-xs text-base-content/70">
      <li :for={reference <- @entries} class="break-all">
        {reference["kind"]}: <a :if={safe_url?(reference["value"])} href={reference["value"]} target="_blank" rel="noopener noreferrer" class="link">{reference["label"] || reference["value"]}</a>
        <span :if={!safe_url?(reference["value"])}>{reference["label"] && reference["label"] <> ": "}{reference["value"]}</span>
        <span :if={reference["revision"]}> · revision {reference["revision"]}</span>
      </li>
    </ul>
    """
  end

  attr(:workstream, :map, required: true)

  defp diagnostics(assigns) do
    ~H"""
    <details id="workstream-diagnostics" phx-hook="DisclosureState" class="rounded-box border border-base-300 p-4">
      <summary class="cursor-pointer text-sm font-semibold focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2">Report history, configuration and diagnostics</summary>
      <div class="mt-3 space-y-4 text-sm">
        <nav aria-label="Workstream tools" class="flex flex-wrap gap-4">
          <.link navigate={@workstream.links.control_room} class="link">Console controls</.link>
          <.link navigate={@workstream.links.conversation} class="link">Full owner conversation</.link>
          <.link navigate={"/contexts/#{URI.encode(@workstream.id, &URI.char_unreserved?/1)}"} class="link">Run context and helpers</.link>
          <.link navigate="/metrics" class="link">Metrics</.link>
        </nav>
        <p class="text-xs text-base-content/60">Configured settings describe desired execution. Applied process settings and captured turn settings describe their own observations. A setting shown here does not confirm a pending change was applied.</p>
        <p class="text-xs text-base-content/60">Pending reconfiguration is not observed in this view.</p>
        <.execution_settings label="Configured for next execution" facts={@workstream.execution.desired} />
        <.execution_settings label="Applied to the observed process" facts={@workstream.execution.applied} />
        <.execution_settings label="Captured for the active turn" facts={@workstream.execution.active} />
        <p :if={@workstream.execution.live_error} class="break-words text-xs text-base-content/60">Observation error: {@workstream.execution.live_error}</p>
        <section>
          <h2 class="font-semibold">Reports in this view</h2>
          <p :if={@workstream.digest.reports == []} class="mt-2 text-base-content/60">No retained reports in this window.</p>
          <details :for={report <- @workstream.digest.reports} id={"workstream-report-#{report.id}"} phx-hook="DisclosureState" class="mt-2 rounded-box border border-base-300 p-3">
            <summary class="cursor-pointer text-xs">Agent report · <.ago at={report.recorded_at} /></summary>
            <div class="mt-2 space-y-2">
              <.foldable_text text={report.summary || "Recorded update without a summary."} markdown id={"history-summary-#{report.id}"} />
              <.interval_report report={report.report} error={report.report_error} id={"history-#{report.id}"} />
              <p class="text-xs text-base-content/60">Verified is agent-authored. Next is reported intent, not a committed agreement step.</p>
            </div>
          </details>
          <p :if={@workstream.digest.has_more_reports} class="mt-2 text-xs text-base-content/60">More reports are in the source conversation.</p>
        </section>
      </div>
    </details>
    """
  end

  attr(:label, :string, required: true)
  attr(:facts, :map, default: nil)

  defp execution_settings(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-semibold">{@label}</h3>
      <p :if={!@facts} class="mt-1 text-xs text-base-content/60">Unavailable.</p>
      <dl :if={@facts} class="mt-1 grid grid-cols-1 gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
        <dt>Provider / model / effort</dt><dd class="break-all font-mono">{@facts.provider || "unknown"} / {@facts.model || "unknown"} / {@facts.effort || "unknown"}</dd>
        <dt>Configuration revision</dt><dd class="break-all font-mono">{@facts.config_revision || "unknown"}</dd>
        <dt>Working directory</dt><dd class="break-all font-mono">{@facts.working_dir || "unknown"}</dd>
      </dl>
    </div>
    """
  end

  attr(:dashboard, :map, required: true)

  defp coverage(assigns) do
    ~H"""
    <footer class="mt-6 space-y-2 border-t border-base-300 pt-4 text-xs text-base-content/60">
      <p>Observed <.ago at={@dashboard.observed_at} /> · {@dashboard.coverage.shown_projects} of {@dashboard.coverage.configured_projects} configured owners · reports from the last {@dashboard.window.hours} hours.</p>
      <p :if={@dashboard.coverage.has_more_projects}>Other configured owners are outside this view. <.link navigate={@dashboard.links.control_room} class="link">Open Console</.link>.</p>
      <p>{@dashboard.evidence} {@dashboard.consistency}</p>
    </footer>
    """
  end

  defp checkpoint_entries(agreements, key) do
    Enum.flat_map(agreements, fn agreement ->
      record = agreement["current"]["checkpoint"]
      entries = if record, do: record["payload"][key], else: []
      Enum.map(entries, &%{item: &1, agreement: agreement, record: record})
    end)
  end

  defp concerns(%{digest: %{reported_concerns: nil}}, _key), do: []
  defp concerns(workstream, key), do: Map.fetch!(workstream.digest.reported_concerns, key)
  defp report_entries(%{report: nil}, _key), do: []
  defp report_entries(report, key), do: report.report[key] || []

  defp next_check_text(at) do
    case until_text(at) do
      "now" -> "due now"
      remaining -> "in #{remaining}"
    end
  end

  defp safe_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _other ->
        false
    end
  end

  defp safe_url?(_value), do: false
end
