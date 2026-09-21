defmodule CustodeWeb.Components do
  @moduledoc """
  Shared function components and badge palettes for the dashboard pages.
  """

  use Phoenix.Component

  alias Custode.Attention
  alias Custode.Signal

  # The one status vocabulary (#31 slice 1). Every surface that shows what an
  # agent is doing -- fleet tile, agent page header, feed card -- reads its word
  # and its color from here, so "awaiting_permission" cannot read as one thing
  # on one page and another elsewhere.
  @status_labels %{
    running: "running",
    idle: "idle",
    awaiting_permission: "needs approval",
    waiting_for_user: "needs answer",
    paused: "paused",
    offline: "offline",
    ended: "ended"
  }

  # The palette (guides/ui-hierarchy.md): red=blocked-on-you,
  # yellow=wants-you, blue=working. Ambient states carry NO badge color --
  # they render as muted text, because the absence of alarm is the signal.
  @status_classes %{
    running: "badge-info",
    awaiting_permission: "badge-warning",
    waiting_for_user: "badge-warning",
    paused: "badge-error"
  }

  @ambient_states [:idle, :offline, :ended]

  @doc "Every status this dashboard has a word for."
  def statuses, do: Map.keys(@status_labels)

  @doc "The operator-facing word for a status (atom or gated `{state, payload}`)."
  def status_label(status) do
    state = status_state(status)
    Map.get(@status_labels, state, to_string(state))
  end

  @doc "The badge class for a status (atom or gated `{state, payload}`)."
  def status_class(status), do: Map.get(@status_classes, status_state(status), "badge-outline")

  @doc "The status an agent is in, whether it arrives bare or gated."
  defdelegate status_state(status), to: Custode, as: :state_of

  attr(:status, :any, required: true)
  attr(:size, :string, default: nil)

  @doc """
  The one status badge. Fleet tile, agent header and feed all render
  through it. Ambient states (idle/offline/ended) demote to muted text --
  rank-4 state never wears a badge (guides/ui-hierarchy.md).
  """
  def status_badge(assigns) do
    assigns = assign(assigns, :ambient, status_state(assigns.status) in @ambient_states)

    ~H"""
    <span :if={@ambient} class="text-xs text-base-content/40">{status_label(@status)}</span>
    <span :if={!@ambient} class={["badge whitespace-nowrap", @size, status_class(@status)]}>
      {status_label(@status)}
    </span>
    """
  end

  @doc """
  Why an agent is paused, when the evidence says so: spend at or past the
  daily rail reads "daily rail" (a pause must say why, #31). nil when the
  reason is not mechanical (manual pause, or no rail configured).
  """
  def paused_reason(spend, budget) when is_number(spend) and is_number(budget) do
    if spend >= budget, do: "daily rail"
  end

  def paused_reason(_spend, _budget), do: nil

  # Feed events that report a status rather than an activity: they render the
  # status vocabulary so the card and the tile that produced it agree.
  @event_statuses %{
    "needs_approval" => :awaiting_permission,
    "needs_input" => :waiting_for_user,
    "budget_paused" => :paused
  }

  @doc "The status a feed event reports, or nil for activity events."
  def status_for_event(event), do: Map.get(@event_statuses, event)

  # Feed categories (#211): the operator's cross-cutting lenses over the
  # event vocabulary, ranked by guides/ui-hierarchy.md. "attention" is the
  # rank-1/2 needs-a-human set; "turns" is the work; "sensors" is the noise
  # you often want to hide. Everything not named here still shows under
  # "all".
  @feed_categories %{
    "attention" => ~w(needs_approval needs_input asked gate_aging ask_aging paused budget_paused
         turn_failed doctor_failed sensor_failed),
    "turns" => ~w(turn prompted),
    # A failed run is under both lenses (#444): it is a sensor line, and it is
    # the one sensor line that is not noise.
    "sensors" => ~w(sensor sensor_failed)
  }

  @doc "The feed filter categories, in display order (#211)."
  def feed_categories, do: ~w(attention turns sensors)

  @doc """
  Does a feed event fall in `category`? `nil` (or "all") matches everything;
  an unknown category matches nothing.
  """
  def feed_category_match?(_event, category) when category in [nil, "all"], do: true

  def feed_category_match?(event, category) do
    event in Map.get(@feed_categories, category, [])
  end

  attr(:entry, :map, required: true)
  attr(:size, :string, default: "badge-xs")

  @doc "A feed card's leading badge: the status vocabulary where the event carries one."
  def event_badge(assigns) do
    assigns = assign(assigns, :status, status_for_event(assigns.entry["event"]))

    ~H"""
    <.status_badge :if={@status} status={@status} size={@size} />
    <span :if={!@status} class={["badge", @size, feed_badge(@entry["event"])]}>
      {@entry["event"]}
    </span>
    """
  end

  @doc "The feed event badge class."
  def feed_badge("turn"), do: "badge-info"
  def feed_badge("advisor_suggestion"), do: "badge-secondary"
  def feed_badge("prompted"), do: "badge-primary"
  def feed_badge("turn_failed"), do: "badge-error"
  def feed_badge("needs_approval"), do: "badge-warning"
  def feed_badge("needs_input"), do: "badge-accent"
  # An ask is a question like needs_input, so it shares the accent hue, but
  # outlined: it did not stop the agent and should not read as loudly (#445).
  def feed_badge("asked"), do: "badge-accent badge-outline"
  # still waiting on the human, said again (#446)
  def feed_badge("gate_aging"), do: "badge-warning"
  def feed_badge("ask_aging"), do: "badge-warning badge-outline"
  def feed_badge("answered"), do: "badge-success badge-outline"
  def feed_badge("budget_paused"), do: "badge-error"
  def feed_badge("workflow_launch_proposed"), do: "badge-warning"
  def feed_badge("workflow_budget_paused"), do: "badge-warning"
  def feed_badge("workflow_complete"), do: "badge-success"
  def feed_badge("workflow_failed"), do: "badge-error"
  def feed_badge("doctor_failed"), do: "badge-error"
  def feed_badge("sensor_failed"), do: "badge-error"
  def feed_badge(_event), do: "badge-ghost"

  attr(:entry, :map, required: true)
  attr(:show_agent, :boolean, default: true)

  @doc "One feed entry card (used by the feed page and the agent detail page)."
  def feed_entry(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body p-3 text-sm">
        <div class="flex items-center gap-2">
          <.event_badge entry={@entry} size="badge-sm" />
          <.resolved_chip entry={@entry} />
          <span class="font-mono text-xs text-base-content/60">
            <.ago at={@entry["at"]} />
            <.link
              :if={@show_agent && agent_linkable?(@entry["agent"])}
              navigate={"/agents/#{@entry["agent"]}"}
              class="link-hover hover:text-base-content"
            >
              {@entry["agent"]}
            </.link>
            <span :if={@show_agent && !agent_linkable?(@entry["agent"])}>{@entry["agent"]}</span>
          </span>
          <%!-- a collapsed run (`Custode.Feed.collapse_repeats/1`): this is the
                newest of N identical arrivals --%>
          <span :if={@entry["repeats"]} class="badge badge-ghost badge-sm font-mono">
            &times;{@entry["repeats"]} since&nbsp;<.ago at={@entry["repeats_since"]} />
          </span>
          <span :if={@entry["cost_usd"]} class="ml-auto font-mono text-xs">
            ${usd(@entry["cost_usd"])}<span :if={@entry["tokens"]} class="text-base-content/50"> &middot; {tok(@entry["tokens"])}</span>
          </span>
        </div>
        <p class="text-base-content/80">{feed_text(@entry)}</p>
        <.prompt_answer entry={@entry} />
      </div>
    </div>
    """
  end

  slot(:inner_block, required: true)
  attr(:fleet_today, :float, required: true)
  attr(:active, :atom, default: :fleet)
  attr(:readouts, :boolean, default: true)
  # Passed by the pages that already hold the data rather than computed here
  # (#301): the count comes from a resolver pass, and running a second one on
  # every page render to decorate a nav link is not worth it. Pages that do
  # not pass it simply show no badge; `attention_chip` still covers "something
  # needs you" everywhere.
  attr(:unread, :integer, default: 0)
  # standing workflow launch gates (#271): a gate nobody sees is a stalled
  # pathway, so the count rides the nav on the pages the operator starts from
  attr(:launch_gates, :integer, default: 0)

  @doc """
  The shared page chrome: header with nav, the attention chip, the fleet spend.

  `readouts={false}` leaves the header plain because the page carries the
  fleet-level readouts itself -- the fleet page's meta rail (#178) owns them.
  """
  def page(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <header class="mb-6 flex items-baseline gap-4">
        <.link navigate="/" class="text-3xl font-bold hover:opacity-70">custode</.link>
        <nav class="flex gap-3 text-sm">
          <.link navigate="/fleet" class={nav_class(@active == :fleet)}>fleet</.link>
          <.link navigate="/console" class={nav_class(false)}>console</.link>
          <.link navigate="/custode" class={nav_class(false)} title="Cmd/Ctrl+K">custode</.link>
          <.link navigate="/inbox" class={nav_class(@active == :inbox)}>
            inbox<span :if={@unread > 0} class="ml-1 font-mono text-warning">{@unread}</span>
          </.link>
          <.link navigate="/repos" class={nav_class(@active == :repos)}>repos</.link>
          <.link navigate="/suggestions" class={nav_class(@active == :suggestions)}>
            suggestions
          </.link>
          <.link navigate="/workflows" class={nav_class(@active == :workflows)}>
            workflows<span :if={@launch_gates > 0} class="ml-1 font-mono text-warning">
              {@launch_gates}
            </span>
          </.link>
          <%!-- /feed leaves the top nav (#301) and keeps its route: a firehose
                is genuinely useful per-agent and useless as a destination. --%>
          <.link navigate="/metrics" class={nav_class(@active == :metrics)}>metrics</.link>
        </nav>
        <.attention_chip :if={@readouts} />
        <span :if={@readouts} class="ml-auto font-mono text-sm text-base-content/70">
          fleet today ${usd(@fleet_today)}
        </span>
        <.theme_toggle />
      </header>
      <.host_banner />
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:html, :string, required: true)

  # THE security boundary for agent-authored panels (#100). It lives in the
  # shared components so the agent page and the console (#450) draw the SAME
  # one: a second copy is a second boundary to keep correct. The untrusted
  # HTML is rendered ONLY here, inside an iframe with an EMPTY sandbox
  # attribute: no scripts run (no allow-scripts), no same-origin, no forms,
  # no navigation, no popups. Inline SVG and CSS render fully, which covers
  # maps/charts/diagrams. HEEx attribute-escapes srcdoc, and the BEAM never
  # executes the content. This component is the ONLY place agent HTML may
  # appear -- never interpolate it into the page anywhere else, including
  # previews (the pending preview reuses THIS component for exactly that
  # reason).
  def sandboxed_panel(assigns) do
    ~H"""
    <iframe
      sandbox=""
      srcdoc={@html}
      class="h-64 w-full rounded-lg border border-base-300 bg-base-100"
      title="agent panel (sandboxed)"
    >
    </iframe>
    """
  end

  attr(:agent, :string, required: true)
  attr(:action, :string, required: true)
  attr(:size, :string, default: "btn-xs")
  # what the button says: "cancel" reads better beside a plan's "do it"
  attr(:label, :string, default: "reject")

  @doc """
  Reject, with a reason (#438). One disclosure shared by every surface that
  can reject a gate, so none of them can send a placeholder again: the form
  will not submit without text, and "one-off" tells the agent not to turn the
  rejection into a standing rule.

  `phx-update="ignore"` keeps a half-typed reason alive across the re-renders
  a live page does every second. The id carries the action id, so a new gate
  is a new element with its own hidden inputs.
  """
  def reject_form(assigns) do
    ~H"""
    <details id={"reject-#{@action}"} phx-update="ignore" class="dropdown dropdown-end">
      <summary class={["btn btn-ghost", @size]}>{@label}</summary>
      <form
        id={"reject-form-#{@action}"}
        phx-submit="reject"
        class="dropdown-content z-10 mt-1 flex w-80 flex-col gap-2 rounded-box bg-base-100 p-3 text-left shadow-lg"
      >
        <input type="hidden" name="agent" value={@agent} />
        <input type="hidden" name="action" value={@action} />
        <textarea
          name="reason"
          rows="3"
          required
          class="textarea textarea-bordered w-full text-sm"
          placeholder="why? the agent reads this, and may make it a rule"
        ></textarea>
        <label class="flex cursor-pointer items-center gap-2 text-xs text-base-content/70">
          <input type="checkbox" name="one_off" value="true" class="checkbox checkbox-xs" />
          one-off: this proposal only, not a standing rule
        </label>
        <button type="submit" class="btn btn-error btn-xs self-end">reject</button>
      </form>
    </details>
    """
  end

  @doc """
  The one condition that outranks a page's own content: the host cannot run
  turns (#443). Drawn by the shared chrome so no page can forget it, and
  because the fleet page builds its tiles per agent and this has no agent.
  """
  def host_banner(assigns) do
    assigns = assign(assigns, :signal, Attention.host(Custode.Host.facts()))

    ~H"""
    <div :if={@signal} role="alert" class="alert alert-error mb-6 items-start">
      <div>
        <p class="font-bold">{@signal.headline}</p>
        <p class="mt-1 font-mono text-xs">{@signal.detail}</p>
      </div>
    </div>
    """
  end

  @doc """
  Switch between the `paper` and `ink` themes (`CustodeWeb.Layouts.theme_css/1`).
  Client-side only: the choice is one attribute on `<html>` and one
  `localStorage` key, read again before first paint on the next load, so no
  LiveView round trip and no server state.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-ghost btn-xs font-mono"
      title="switch between the paper and ink themes"
      onclick="(()=>{const r=document.documentElement;const t=r.dataset.theme==='ink'?'paper':'ink';r.dataset.theme=t;localStorage.setItem('custode-theme',t);})()"
    >
      theme
    </button>
    """
  end

  attr(:class, :string, default: nil)

  @doc """
  Who is waiting on a human, or nothing at all when the fleet is calm.
  A badge stays a one-liner; long attention lists (several agents at
  once) need `wrap` -- a soft warning block that wraps instead of
  spilling out of its pill (#31's rail).

  It opens the console (#481). The count comes from every signal, including
  the ones with no agent behind them (a workflow launch, a parked run), and
  the fleet page draws only per-agent tiles, so the chip used to say "1 need
  you" above a page showing nothing that did. The console draws every signal
  the chip counts and opens on the one that most needs the operator.
  """
  attr(:wrap, :boolean, default: false)

  def attention_chip(assigns) do
    assigns = assign(assigns, :attention, attention())

    ~H"""
    <.link
      :if={@attention != [] && @wrap}
      navigate="/console"
      class={[
        "block rounded-lg bg-warning/20 px-2 py-1 text-xs font-medium text-warning-content/80",
        @class
      ]}
    >
      {attention_text(@attention)}
    </.link>
    <.link
      :if={@attention != [] && !@wrap}
      navigate="/console"
      class={["badge badge-warning gap-1 whitespace-nowrap", @class]}
    >
      {attention_text(@attention)}
    </.link>
    """
  end

  defp agent_linkable?(agent), do: is_binary(agent) and agent not in ["", "?"]

  attr(:entry, :map, required: true)

  @doc "The worked-it chip on gate cards: what happened, and how long it waited."
  def resolved_chip(assigns) do
    ~H"""
    <span
      :if={@entry["resolved"]}
      class={[
        "badge badge-xs gap-1",
        (@entry["resolved"] == "rejected" && "badge-ghost") || "badge-success badge-outline"
      ]}
      title={@entry["resolved_at"]}
    >
      {if @entry["resolved"] == "rejected", do: "✗", else: "✓"} {@entry["resolved"]}
      <span :if={wait_minutes(@entry)} class="opacity-60">after {wait_minutes(@entry)}m</span>
    </span>
    """
  end

  defp wait_minutes(%{"at" => at, "resolved_at" => resolved_at})
       when is_binary(at) and is_binary(resolved_at) do
    with {:ok, opened, _o1} <- DateTime.from_iso8601(at),
         {:ok, closed, _o2} <- DateTime.from_iso8601(resolved_at) do
      minutes = div(DateTime.diff(closed, opened), 60)
      if minutes > 0, do: minutes
    else
      _bad -> nil
    end
  end

  defp wait_minutes(_entry), do: nil

  @doc "Budget progress color: calm until 60%, warning to 90%, error past."
  def budget_progress_class(spend, budget) when is_number(spend) and is_number(budget) do
    cond do
      budget <= 0 -> "progress-success"
      spend / budget >= 0.9 -> "progress-error"
      spend / budget >= 0.6 -> "progress-warning"
      true -> "progress-success"
    end
  end

  @doc "The feed event dot color for timeline middles."
  def event_dot("turn"), do: "text-info"
  def event_dot("turn_failed"), do: "text-error"
  def event_dot("needs_approval"), do: "text-warning"
  def event_dot("needs_input"), do: "text-accent"
  def event_dot("asked"), do: "text-accent"
  def event_dot("gate_aging"), do: "text-warning"
  def event_dot("ask_aging"), do: "text-warning"
  def event_dot("answered"), do: "text-success"
  def event_dot("budget_paused"), do: "text-error"
  def event_dot("doctor_failed"), do: "text-error"
  def event_dot("sensor_failed"), do: "text-error"
  def event_dot("repo_verb"), do: "text-success"
  def event_dot(_event), do: "text-base-content/30"

  attr(:text, :string, required: true)

  @doc """
  Markdown for agent output (journal tables and friends), rendered by MDEx
  (#460). Three layers keep agent text inert: raw HTML is escaped rather
  than rendered, the rendered markup passes through the sanitizer (which
  drops event-handler attributes and empties `javascript:`, `data:` and
  other unsafe URL schemes), and no attribute syntax is enabled. Falls back
  to plain text if rendering fails.
  """
  def markdown(assigns) do
    ~H"""
    <div class="agent-md text-base-content/80">{render_markdown(@text)}</div>
    """
  end

  @markdown_options [
    extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
    render: [hardbreaks: true, unsafe: false, escape: true]
  ]

  defp render_markdown(text) do
    options = [{:sanitize, MDEx.Document.default_sanitize_options()} | @markdown_options]

    case MDEx.to_html(text, options) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _reason} -> text
    end
  end

  attr(:entry, :map, required: true)
  attr(:id, :string, default: nil)

  @doc "One daisyUI timeline item for the feed page (#31: right component)."
  def timeline_item(assigns) do
    ~H"""
    <li id={@id}>
      <hr />
      <div class="timeline-start pr-2 text-right font-mono text-xs text-base-content/50">
        <.ago at={@entry["at"]} />
        <div>
          <.link
            :if={agent_linkable?(@entry["agent"])}
            navigate={"/agents/#{@entry["agent"]}"}
            class="link-hover"
          >
            {@entry["agent"]}
          </.link>
        </div>
      </div>
      <div class="timeline-middle">
        <svg viewBox="0 0 16 16" class={["h-3 w-3", event_dot(@entry["event"])]}>
          <circle cx="8" cy="8" r="6" fill="currentColor" />
        </svg>
      </div>
      <div class="timeline-end timeline-box mb-2 w-full bg-base-100 text-sm">
        <div class="mb-1 flex items-center gap-2">
          <.event_badge entry={@entry} />
          <.resolved_chip entry={@entry} />
          <span :if={@entry["cost_usd"]} class="ml-auto font-mono text-xs text-base-content/50">
            ${usd(@entry["cost_usd"])}<span :if={@entry["tokens"]}> &middot; {tok(@entry["tokens"])}</span>
          </span>
        </div>
        <p class="whitespace-pre-wrap text-base-content/80">{feed_text(@entry)}</p>
        <.prompt_answer entry={@entry} />
      </div>
      <hr />
    </li>
    """
  end

  attr(:entry, :map, required: true)

  @doc """
  The durable answer to an operator prompt (#138). Operator-origin turns
  carry the full response on the feed entry; sweeps stay summary-only.
  Rendered expanded -- the operator asked, so the answer leads.
  """
  def prompt_answer(assigns) do
    agent = assigns.entry["agent"]
    {response, response_images} = attachments(assigns.entry["response"], agent)
    {prompt, prompt_images} = attachments(prompt_text(assigns.entry), agent)

    assigns =
      assign(assigns,
        response: response,
        response_images: response_images,
        prompt: prompt,
        prompt_images: prompt_images
      )

    ~H"""
    <div
      :if={@response || @response_images != []}
      class="agent-md mt-2 rounded border-l-2 border-primary/40 bg-base-200/60 p-2 text-sm"
    >
      <.markdown :if={@response} text={@response} />
      <.image_thumbnails images={@response_images} />
    </div>
    <div
      :if={@prompt || @prompt_images != []}
      class="mt-2 rounded border-l-2 border-primary/40 bg-base-200/60 p-2 text-sm"
    >
      <div :if={@prompt} class="whitespace-pre-wrap font-mono">{@prompt}</div>
      <.image_thumbnails images={@prompt_images} />
    </div>
    """
  end

  attr(:images, :list, required: true)

  @doc """
  The images that rode along with a prompt (#180 slice 3), as thumbnails.

  Each links to the full-size file on the agent's own upload route. An image
  the janitor has already aged out of `uploads/` (`:uploads_days`, 30 by
  default, while the feed entry naming it lives 90) renders as a filename
  chip instead -- the attachment happened either way, and a chip says so
  where a broken image would not.
  """
  def image_thumbnails(assigns) do
    ~H"""
    <div :if={@images != []} class="mt-2 flex flex-wrap items-center gap-2">
      <a
        :for={image <- @images}
        :if={image.url}
        href={image.url}
        target="_blank"
        rel="noopener"
        title={image.path}
      >
        <img
          src={image.url}
          alt={image.name}
          class="h-24 w-24 rounded border border-base-300 object-cover"
        />
      </a>
      <span
        :for={image <- @images}
        :if={is_nil(image.url)}
        class="badge badge-ghost badge-sm font-mono"
        title={image.path}
      >
        {image.name}
      </span>
    </div>
    """
  end

  # Only a `prompted` entry carries the operator's own words; every other
  # event's `prompt`, if any, is not the thing this block shows.
  defp prompt_text(%{"event" => "prompted"} = entry), do: entry["prompt"]
  defp prompt_text(_entry), do: nil

  # The line agent_live composes onto a prompt when an image rides along
  # (#180): `attached image: <absolute path> -- Read it before answering`.
  # It is plumbing addressed to the agent, so once the picture renders the
  # sentence is noise -- the text keeps the operator's words, the thumbnail
  # carries the attachment.
  @attachment_line ~r/^attached image: (\S+)(?: -- [^\n]*)?$/m

  defp attachments(text, agent) when is_binary(text) do
    images =
      @attachment_line
      |> Regex.scan(text)
      |> Enum.map(fn [_line, path] ->
        %{path: path, name: Path.basename(path), url: Custode.Uploads.url(agent, path)}
      end)

    case text |> String.replace(@attachment_line, "") |> String.trim() do
      "" -> {nil, images}
      remaining -> {remaining, images}
    end
  end

  defp attachments(_text, _agent), do: {nil, []}

  attr(:overview, :any, required: true)

  @doc """
  The issues/PRs two-card panel for a repo overview -- shared by the agent
  page, the repositories page (#193) and the console's work tab. Renders
  nothing until the overview map arrives (`Custode.GitHub.overview/2`
  broadcasts when it does).

  `{:error, reason}` renders the reason in the panel's place (#485). A repo
  GitHub refuses never gets an overview, and drawing nothing there read as a
  loading state that never ended.
  """
  def repo_overview_panel(%{overview: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="rounded-lg bg-base-100 p-3 text-sm shadow-sm">
      <span class="text-warning">GitHub refused this repository: {@reason}</span>
      <span class="ml-1 text-xs text-base-content/50">custode retries on a backoff</span>
    </p>
    """
  end

  def repo_overview_panel(assigns) do
    ~H"""
    <div :if={is_map(@overview)} class="grid grid-cols-1 gap-4 xl:grid-cols-2">
      <div class="rounded-lg bg-base-100 p-3 shadow-sm">
        <p class="mb-2 text-sm font-semibold">
          issues <span class="badge badge-ghost badge-sm">{@overview.open_issues.total} open</span>
        </p>
        <.repo_item :for={item <- @overview.open_issues.items} item={item} />
        <p
          :if={@overview.closed_issues.items != []}
          class="mb-1 mt-3 text-xs font-semibold text-base-content/50"
        >
          recently closed
        </p>
        <.repo_item :for={item <- @overview.closed_issues.items} item={item} closed />
      </div>
      <div class="rounded-lg bg-base-100 p-3 shadow-sm">
        <p class="mb-2 text-sm font-semibold">
          pull requests
          <span class="badge badge-ghost badge-sm">{@overview.open_prs.total} open</span>
        </p>
        <p :if={@overview.open_prs.items == []} class="text-xs text-base-content/40">
          (none open)
        </p>
        <.repo_item :for={item <- @overview.open_prs.items} item={item} />
        <p
          :if={@overview.merged_prs.items != []}
          class="mb-1 mt-3 text-xs font-semibold text-base-content/50"
        >
          recently merged
        </p>
        <.repo_item :for={item <- @overview.merged_prs.items} item={item} closed />
      </div>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:closed, :boolean, default: false)

  @doc """
  One issue or pull request row of a repo overview: its number and title as a
  link, a check dot when the item carries checks, a draft badge. Public so the
  console's attention tab draws a row exactly as the overview panel does.
  """
  def repo_item(assigns) do
    ~H"""
    <p class="flex items-center gap-2 truncate py-0.5 text-sm">
      <span :if={Map.has_key?(@item, :checks)} class={["inline-block h-2 w-2 shrink-0 rounded-full", check_dot(@item.checks)]} title={"checks: #{@item.checks || "none"}"}>
      </span>
      <a href={@item.url} target="_blank" class="link link-hover truncate">
        <span class={["font-mono text-xs", (@closed && "text-base-content/40") || "text-base-content/60"]}>
          #{@item.number}
        </span>
        <span class={@closed && "text-base-content/50"}>{@item.title}</span>
      </a>
      <span :if={@item[:draft]} class="badge badge-ghost badge-xs shrink-0">draft</span>
    </p>
    """
  end

  defp check_dot("SUCCESS"), do: "bg-success"
  defp check_dot("FAILURE"), do: "bg-error"
  defp check_dot("ERROR"), do: "bg-error"
  defp check_dot(state) when state in ["PENDING", "EXPECTED"], do: "bg-warning"
  defp check_dot(_none), do: "bg-base-content/20"

  @doc "Dollar amounts render with two decimals everywhere (#31)."
  def usd(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @doc """
  Relative time for feed/journal stamps (#31): "4m ago" reads at a glance
  where "20:15:01" (UTC, while the operator lives in local time) does not.
  The absolute stamp stays available on hover via the title attribute.
  """
  attr(:at, :any, required: true)

  def ago(assigns) do
    ~H"""
    <span title={@at}>{ago_text(@at)}</span>
    """
  end

  @doc false
  def ago_text(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 0 -> "now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  def ago_text(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> ago_text(parsed)
      {:error, _reason} -> at
    end
  end

  def ago_text(_other), do: "?"

  @doc """
  How long until `at`, as the rail prints it beside a scheduled agent: "40s",
  "12m", "3h", "2d". A time already past is "now": the beat is due and the
  queue has it.
  """
  @spec until_text(DateTime.t(), DateTime.t()) :: String.t()
  def until_text(%DateTime{} = at, %DateTime{} = now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(at, now)

    cond do
      seconds <= 0 -> "now"
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  @doc "Token counts render compact: 900, 45k, 2.4M (#30)."
  def tok(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M tok"
  def tok(count) when count >= 1_000, do: "#{round(count / 1_000)}k tok"
  def tok(count) when is_integer(count), do: "#{count} tok"

  @doc """
  The text of a feed card. Failure events carry a what-happens-next hint --
  a bare rail kind ("max_turns_exceeded") tells the operator what broke but
  not whether anyone has to do anything (#31).
  """
  def feed_text(%{"event" => "turn_failed"} = entry) do
    base = "#{entry["kind"]} -- #{failure_hint(entry["kind"])}"

    case entry["detail"] do
      detail when is_binary(detail) and detail != "" -> base <> "\n" <> detail
      _absent -> base
    end
  end

  def feed_text(%{"event" => "budget_paused"}),
    do: "daily budget rail crossed; auto-paused until a human resumes"

  def feed_text(entry),
    do: entry["summary"] || entry["action"] || entry["question"] || entry["kind"]

  defp failure_hint("max_turns_exceeded"),
    do:
      "turn cap hit mid-run; if this was an approval it re-gated, and re-approving grants a fresh turn budget"

  defp failure_hint("max_budget_exceeded"),
    do: "per-turn cost cap hit; a re-approval retries, or raise the routine's max_budget_usd"

  defp failure_hint("timeout"),
    do: "subprocess time cap hit; a re-approval retries, or raise the routine's timeout_ms"

  defp failure_hint(_kind),
    do: "the next beat retries; check the machine log if it repeats"

  @attention_states [:awaiting_permission, :waiting_for_user, :paused]

  @doc "Does this status (atom or gated tuple) need a human?"
  def needs_attention?({state, _payload}), do: state in @attention_states
  def needs_attention?(state), do: state in @attention_states

  # Reads the resolver rather than filtering statuses itself (#298), so this
  # chip and the fleet page's NEEDS YOU header cannot disagree. The visible
  # change: a PAUSED agent stops being counted. `needs_attention?/1` still
  # includes it, and still should -- it also decides which feed message a tile
  # shows -- but a deliberate stop is not something waiting on a human.
  defp attention do
    for signal <- Attention.Fleet.signals(), Signal.needs_you?(signal) do
      {signal.subject, chip_word(signal.kind)}
    end
  end

  defp chip_word(:host_down), do: "cannot run turns"
  defp chip_word(:needs_answer), do: "asked you"
  defp chip_word(:approval), do: "needs approval"
  defp chip_word(:workflow_launch), do: "awaits your launch approval"
  defp chip_word(:workflow_rail), do: "is parked on its run rail"
  defp chip_word(:rail_hit), do: "at its rail"
  defp chip_word(kind), do: to_string(kind)

  # "custode paused" reads as the actual situation; a bare count reads as
  # "something somewhere" and goes stale in the operator's head the moment
  # they resolve any one thing. Name the subjects while the list is short.
  defp attention_text(attention) when length(attention) <= 2,
    do: Enum.map_join(attention, ", ", fn {id, word} -> "#{id} #{word}" end)

  defp attention_text(attention), do: "#{length(attention)} need attention"

  defp nav_class(true), do: "font-semibold underline underline-offset-4"
  defp nav_class(false), do: "text-base-content/60 hover:text-base-content"
end
