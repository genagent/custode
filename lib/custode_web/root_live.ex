defmodule CustodeWeb.RootLive do
  @moduledoc """
  Talking to custode (#451), from `custode-root.png`: a sentence, the plan it
  comes back with, and what it did while the operator was away.

  This is a VIEW over the caretaker that already exists, and it gives custode
  no authority it does not have. The sentence is
  `Custode.Operator.Actions.tell_custode/2`. "custode will" is the caretaker's
  own open approval gate: its roster and profile tools already raise one whose
  action IS the rendered change, so the gate's text is the plan, `do it` is an
  approval and `cancel` is a rejection with a reason (#438). Every handler is
  one call into `Custode.Operator.*` (design/010 decision 4).
  """

  use Phoenix.LiveView

  import CustodeWeb.Components,
    only: [ago: 1, app_header: 1, feed_entry: 1, host_banner: 1, markdown: 1, reject_form: 1]

  alias Custode.Operator.Actions

  @opts [via: :liveview]

  # Sentences that map to things the caretaker can already do. A click fills
  # the box and does not send: they are prompts for the operator, not macros.
  @also_try [
    "what needs me right now, and what can wait until tomorrow?",
    "pause everything except mdbook-lint until Monday",
    "which agents have not changed an outcome in 14 days?",
    "add a routine for a new repository, same role as git-spawn",
    "tell every backlog worker to stop opening docs-only PRs"
  ]

  # How far back "while you were away" reads when presence gives no better
  # answer, and how many entries it shows.
  @away_window_s 24 * 60 * 60
  @did_limit 12

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    {:ok, socket |> assign(draft: "", sent_gen: 0, notice: nil) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("tell", %{"text" => text}, socket) do
    case Actions.tell_custode(text, @opts) do
      {:ok, how} ->
        {:noreply,
         socket
         |> assign(draft: "", sent_gen: socket.assigns.sent_gen + 1, notice: sent_notice(how))
         |> refresh()}

      {:error, :empty} ->
        {:noreply, socket}

      {:error, :no_caretaker} ->
        {:noreply, assign(socket, notice: "no caretaker: no routine is tagged :meta")}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "failed: #{inspect(reason)}")}
    end
  end

  def handle_event("try", %{"sentence" => sentence}, socket) when sentence in @also_try,
    do: {:noreply, assign(socket, draft: sentence, sent_gen: socket.assigns.sent_gen + 1)}

  # The plan's args come from the caretaker's open gate, never from the
  # client, so a stale or forged click cannot approve something else.
  def handle_event("do_it", _params, socket) do
    case socket.assigns.plan do
      %{action_id: action_id} ->
        socket.assigns.caretaker
        |> Actions.approve(action_id, @opts)
        |> decided(socket, "approved: custode is doing it")

      nil ->
        {:noreply, socket |> assign(notice: "that is no longer pending") |> refresh()}
    end
  end

  # The shared reject form (#438) posts agent, action, reason and one_off.
  def handle_event("reject", %{"agent" => agent, "action" => action} = params, socket) do
    :reject
    |> Actions.run(%{agent: agent, action: action}, params, @opts)
    |> decided(socket, "cancelled")
  end

  defp decided(:ok, socket, notice), do: {:noreply, socket |> assign(notice: notice) |> refresh()}

  defp decided({:error, reason}, socket, _notice),
    do: {:noreply, socket |> assign(notice: "failed: #{inspect(reason)}") |> refresh()}

  defp sent_notice(:delivered), do: "sent"
  defp sent_notice(:queued), do: "queued for the next safe turn"
  defp sent_notice(:resumed), do: "custode was paused: resumed, then sent"
  defp sent_notice(:started), do: "custode was offline: started a turn with your sentence"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.app_header active={:custode} fleet_today={@fleet_today} />
      <main id="custode-root" class="mx-auto flex max-w-4xl flex-col px-6 py-5">
        <div class="flex items-baseline gap-4 border-b border-base-300 pb-4">
        <span class="font-mono text-sm text-base-content/50">
          root &middot; sees every agent &middot; speaks for you
        </span>
          <.link navigate="/" class="ml-auto font-mono text-xs text-base-content/40 hover:text-base-content">
            esc to close
          </.link>
        </div>

        <div class="pt-4 empty:hidden"><.host_banner /></div>

      <p :if={@caretaker == nil} class="mt-8 text-sm text-warning">
        No routine is tagged <span class="font-mono">meta</span>, so there is no custode to talk to.
      </p>

      <form
        :if={@caretaker}
        id={"tell-#{@sent_gen}"}
        phx-submit="tell"
        class="mt-6 flex items-start gap-3 rounded-xl border border-base-300 bg-base-100 px-4 py-3"
      >
        <span class="pt-1 font-mono text-base-content/40">&rsaquo;</span>
        <textarea
          name="text"
          rows="2"
          required
          autofocus
          placeholder="tell custode..."
          class="w-full resize-none border-0 bg-transparent font-mono text-lg outline-none ring-0 placeholder:text-base-content/30 focus:outline-none focus:ring-0"
        >{@draft}</textarea>
        <button type="submit" class="btn btn-primary btn-sm">send</button>
      </form>
      <p :if={@notice} id="root-notice" class="mt-2 font-mono text-xs text-base-content/60">
        {@notice}
      </p>

      <section :if={@plan} id="custode-will" class="mt-8">
        <.label>custode will</.label>
        <div class="rounded-xl border border-base-300 bg-base-100 p-4">
          <.markdown text={@plan.detail || "(no detail recorded)"} />
        </div>
        <div class="mt-3 flex flex-wrap items-start gap-3">
          <button class="btn btn-primary" phx-click="do_it">do it</button>
          <.reject_form agent={@caretaker} action={@plan.action_id} label="cancel" size="btn-md" />
          <span class="self-center font-mono text-xs text-base-content/40">
            raised <.ago at={@plan.inserted_at} />
          </span>
        </div>
      </section>

      <section :if={@said != []} id="custode-said" class="mt-8">
        <.label>custode said</.label>
        <div class="flex flex-col gap-2">
          <.feed_entry :for={entry <- @said} entry={entry} show_agent={false} />
        </div>
      </section>

      <section :if={@caretaker} class="mt-8">
        <.label>also try</.label>
        <button
          :for={sentence <- @also_try}
          type="button"
          phx-click="try"
          phx-value-sentence={sentence}
          class="mb-2 block w-full rounded-lg bg-base-100 px-4 py-2.5 text-left font-mono text-sm text-base-content/80 hover:text-base-content"
        >
          {sentence}
        </button>
      </section>

        <section id="custode-did" class="mt-8 border-t border-base-300 pt-6">
          <.label>what custode did {@did_since}</.label>
          <p :if={@did == []} class="text-sm text-base-content/50">nothing but its sweeps</p>
          <div :for={entry <- @did} class="flex gap-4 py-1 font-mono text-sm">
            <span class="w-16 shrink-0 text-base-content/40"><.ago at={entry["at"]} /></span>
            <span class="min-w-0 text-base-content/80">{entry["summary"] || entry["event"]}</span>
          </div>
        </section>
      </main>
    </div>
    """
  end

  slot(:inner_block, required: true)

  defp label(assigns) do
    ~H"""
    <h2 class="mb-3 font-mono text-xs font-bold uppercase tracking-widest text-base-content/50">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  # -- data -------------------------------------------------------------------

  defp refresh(socket) do
    caretaker = Actions.caretaker()
    feed = if caretaker, do: caretaker |> Custode.Feed.for_agent(150) |> Enum.reverse(), else: []
    {since, since_words} = away_since()

    assign(socket,
      caretaker: caretaker,
      also_try: @also_try,
      plan: caretaker && plan(caretaker),
      said: feed |> Custode.Feed.said() |> Enum.reject(&gate_event?/1) |> Enum.take(3),
      did: did(feed, since),
      did_since: since_words,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  # A proposal is drawn as the plan while it is pending, so its feed entry
  # would say the same thing twice, and as raw markdown.
  defp gate_event?(entry), do: entry["event"] in ["needs_approval", "needs_input"]

  # The caretaker's open approval gate is its proposal.
  defp plan(caretaker) do
    caretaker
    |> Custode.Gates.open_gates()
    |> Enum.find(&(&1.kind == "approval"))
  end

  # What it DID, not what it said or sensed: everything in its feed that is
  # neither its own turn reports nor a sensor ping, since the operator left.
  defp did(feed, since) do
    said = MapSet.new(Custode.Feed.said(feed))

    feed
    |> Enum.reject(&(&1["event"] in ["sensor", "sensor_failed"] or MapSet.member?(said, &1)))
    |> Enum.filter(&after?(&1["at"], since))
    |> Enum.take(@did_limit)
  end

  defp after?(at, since) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> DateTime.compare(parsed, since) != :lt
      {:error, _reason} -> false
    end
  end

  defp after?(_at, _since), do: false

  # "While you were away" when presence knows when that began; the last day
  # otherwise, and the heading says which.
  defp away_since do
    case Custode.Presence.status() do
      {:away, %DateTime{} = at} -> {at, "while you were away"}
      _present -> {DateTime.add(DateTime.utc_now(), -@away_window_s, :second), "in the last day"}
    end
  end
end
