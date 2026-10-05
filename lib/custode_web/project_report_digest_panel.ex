defmodule CustodeWeb.ProjectReportDigestPanel do
  @moduledoc "One compact manager view over the shared project-report digest."
  use Phoenix.Component
  import CustodeWeb.Components, only: [ago: 1, interval_report: 1]

  attr(:digest, :map, required: true)

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:updated, Enum.filter(assigns.digest.projects, &(&1.reports != [])))
      |> assign(:reported, Enum.filter(assigns.digest.projects, & &1.reported_concerns))
      |> assign(:waiting, Enum.filter(assigns.digest.projects, &waiting?/1))
      |> assign(:missing, Enum.count(assigns.digest.projects, &(&1.freshness.state == "missing")))
      |> assign(:stale, Enum.count(assigns.digest.projects, &(&1.freshness.state == "stale")))

    ~H"""
    <details id="project-report-digest" phx-hook="DisclosureState" class="rounded-box border border-base-300 bg-base-100 p-4">
      <summary class="cursor-pointer font-semibold">
        Project digest · {length(@updated)} updated · {length(@waiting)} need a decision
      </summary>
      <div class="mt-3 space-y-4 text-sm">
        <p class="text-xs text-base-content/60">
          Last {@digest.window.hours} hours · {@digest.coverage.shown_projects} of {@digest.coverage.configured_projects} configured owners.
          Reports are agent-authored; Verified entries are claims, not independent checks or acceptance.
        </p>
        <p :if={@digest.coverage.has_more_projects} data-project-digest-truncated class="text-warning">
          More owners are outside this bounded view. <.link navigate="/console" class="link">Open the fleet</.link>.
        </p>
        <section data-project-digest-section="changed">
          <h2 class="font-semibold">Changed · reported updates</h2>
          <p :if={@updated == []} class="text-base-content/60">No retained updates in this window. This does not establish inactivity.</p>
          <article :for={project <- @updated} data-project-digest-owner={project.owner} class="mt-2 border-t border-base-300 pt-2">
            <.link navigate={project.links.conversation} class="link font-mono font-semibold">{project.owner}</.link>
            <p :if={project.repo} class="text-xs text-base-content/60">{project.repo}</p>
            <div :for={report <- project.reports} id={"project-digest-report-#{report.id}"} class="mt-2">
              <p class="text-xs text-base-content/60"><.ago at={report.recorded_at} /> · {if report.event == "turn_failed", do: "Recorded failed turn", else: "Agent report"}</p>
              <p class="whitespace-pre-wrap break-words">{report.summary || "Recorded update"}</p>
              <.interval_report report={report.report} error={report.report_error} id={"digest-interval-#{report.id}"} />
            </div>
            <p :if={project.has_more_reports} class="text-xs text-base-content/60">More updates in this window are in the source conversation.</p>
          </article>
        </section>
        <section data-project-digest-section="blocked">
          <h2 class="font-semibold">Blocked · agent-reported concerns</h2>
          <p :if={@reported == []} class="text-base-content/60">No concerns in the latest retained typed reports. Current decisions are shown separately.</p>
          <article :for={project <- @reported} class="mt-2">
            <.link navigate={project.links.conversation} class="link font-mono">{project.owner}</.link>
            <span class="text-xs text-base-content/60"> · last reported <.ago at={project.reported_concerns.recorded_at} /> · resolution not established</span>
            <ul class="list-inside list-disc break-words"><li :for={text <- project.reported_concerns.blockers}>{text}</li></ul>
            <ul class="list-inside list-disc break-words"><li :for={text <- project.reported_concerns.decisions}>Reported decision: {text}</li></ul>
          </article>
        </section>
        <section data-project-digest-section="decisions">
          <h2 class="font-semibold">Needs a decision · current open records</h2>
          <p :if={@waiting == []} class="text-base-content/60">No open asks or gates for the shown owners.</p>
          <article :for={project <- @waiting} class="mt-2">
            <.link navigate={project.links.control_room} class="link font-mono">{project.owner}</.link>
            <ul class="mt-1 space-y-1">
              <li :for={decision <- project.decisions.gates ++ project.decisions.asks} class="break-words">
                <span class="font-semibold">{if decision.blocking, do: "Waiting at a gate", else: "Open question"} #{decision.id}</span>
                <span class="text-xs text-base-content/60"> · opened <.ago at={decision.opened_at} /></span>
                <p>{decision.text}</p>
              </li>
            </ul>
            <p :if={project.decisions.has_more_asks || project.decisions.has_more_gates} class="text-xs text-warning">More open decisions are in the control room and Inbox.</p>
          </article>
        </section>
        <details id="project-report-freshness" phx-hook="DisclosureState">
          <summary class="cursor-pointer text-xs">Report coverage · {@missing} missing · {@stale} older than 48 hours</summary>
          <ul class="mt-2 space-y-1 text-xs">
            <li :for={project <- @digest.projects}>
              <.link navigate={project.links.conversation} class="link font-mono">{project.owner}</.link>
              · {project.freshness.state}
              <span :if={project.freshness.latest_recorded_at}> · <.ago at={project.freshness.latest_recorded_at} /></span>
              <span :if={not project.freshness.within_window}> · no retained update in this window</span>
              <span :if={project.execution.applied}> · live {project.execution.applied.state}</span>
              <span :if={project.execution.observation_error}> · live state unavailable</span>
            </li>
          </ul>
        </details>
        <p class="text-xs text-base-content/60">{@digest.coverage.scope} <.link navigate={@digest.links.inbox} class="link">Open Inbox</.link>. Read at {@digest.observed_at}; independent observations, not an atomic snapshot.</p>
      </div>
    </details>
    """
  end

  defp waiting?(project), do: project.decisions.asks != [] or project.decisions.gates != []
end
