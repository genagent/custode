defmodule CustodeWeb.FleetLive do
  @moduledoc """
  The fleet at a glance: one compact tile per agent (routines first, then any
  other running agents), each carrying its live status, spend, and last
  message, with the fastest actions inline (approve/reject a gate, beat an
  offline routine). Click through an agent's name for the full detail page.

  All reads go through the facade; all pushes arrive over
  `Custode.PubSubBridge` -- no polling anywhere.
  """

  use Phoenix.LiveView

  alias Custode.Config.WriteBack

  import CustodeWeb.Components

  alias Custode.Attention
  alias Custode.Routine
  alias ObanClaude.Agent

  # the rail shows the top few suggestions; the rest live on /suggestions (#284)
  @suggestion_limit 3

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Custode.PubSubBridge.subscribe()
      # the in-flight clock ticks even mid-turn, when no other event fires --
      # so a long-running (or stuck) turn's elapsed keeps climbing (#211)
      :timer.send_interval(5_000, self(), :inflight_tick)
    end

    {:ok,
     socket
     |> assign(tag_filter: nil, new_agent: %{open: false, preview: nil, error: nil, params: %{}})
     |> assign(away_dismissed: false, quiet_open: false)
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}
  # a cheap tick: re-read only the in-flight clock, not the whole fleet
  def handle_info(:inflight_tick, socket), do: {:noreply, assign(socket, in_flight: in_flight())}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("beat", %{"id" => id}, socket) do
    {:ok, _job} = Custode.beat(id)
    {:noreply, socket}
  end

  def handle_event("approve", %{"id" => id, "action" => action_id}, socket) do
    Agent.approve_action(id, action_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"id" => id, "action" => action_id}, socket) do
    Custode.reject_with_note(id, action_id, "rejected from dashboard")
    {:noreply, refresh(socket)}
  end

  # the quiet group collapses to a line of names (#298); expanding it is a
  # per-session view preference, so it lives in the socket and not in config
  def handle_event("toggle_quiet", _params, socket) do
    {:noreply, assign(socket, quiet_open: !socket.assigns.quiet_open)}
  end

  # present -> pin away; away -> back to inference (the toggle itself counts
  # as an operator action, so the reading flips to present and then expires
  # with the window instead of needing a forever-pin)
  def handle_event("toggle_presence", _params, socket) do
    case socket.assigns.presence do
      {:present, _at} -> Custode.Presence.set(:away)
      {:away, _at} -> Custode.Presence.set(:auto)
    end

    {:noreply, refresh(socket)}
  end

  # dismissing the "while you were away" digest (#263): sticky for this session
  # so a refresh does not bring it back until the next real absence
  def handle_event("dismiss_away_digest", _params, socket) do
    {:noreply, assign(socket, away_dismissed: true, away_digest: nil)}
  end

  # the rail's caretaker prompt (a static conversation entry, not a tile
  # click-through); same cast semantics as the agent page's box
  def handle_event("rail_prompt", %{"agent" => id, "text" => text}, socket) do
    if String.trim(text) == "" do
      {:noreply, socket}
    else
      Agent.cast_prompt(id, text)
      Custode.Feed.record_prompted(id, text)
      {:noreply, socket |> put_flash(:info, "sent to #{id}") |> refresh()}
    end
  end

  def handle_event("apply_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    case Custode.Suggestions.apply(id, field, proposed) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "apply refused: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params
    {:ok, message} = Custode.Suggestions.dismiss(id, field, proposed)
    {:noreply, socket |> put_flash(:info, message) |> refresh()}
  end

  def handle_event("pause_all", _params, socket) do
    {:ok, _ids} = Custode.pause_all()
    {:noreply, refresh(socket)}
  end

  def handle_event("resume_all", _params, socket) do
    {:ok, _ids} = Custode.resume_all()
    {:noreply, refresh(socket)}
  end

  # The new-agent form (#75 / design 001 slice 4): the human's own authority
  # (D5) driving the same WriteBack every other surface uses -- file + live
  # roster in one operation, the preview being the literal text appended.
  def handle_event("new_agent_open", _params, socket) do
    {:noreply, assign(socket, new_agent: %{open: true, preview: nil, error: nil, params: %{}})}
  end

  def handle_event("new_agent_close", _params, socket) do
    {:noreply, assign(socket, new_agent: %{open: false, preview: nil, error: nil, params: %{}})}
  end

  def handle_event("new_agent_change", %{"routine" => params}, socket) do
    new_agent =
      case form_attrs(params) do
        {:ok, attrs} ->
          %{open: true, preview: WriteBack.render_routine(attrs), error: nil, params: params}

        {:error, message} ->
          %{open: true, preview: nil, error: message, params: params}
      end

    {:noreply, assign(socket, new_agent: new_agent)}
  end

  def handle_event("new_agent_create", %{"routine" => params}, socket) do
    with {:ok, attrs} <- form_attrs(params),
         {:ok, path} <- WriteBack.add_routine(attrs) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: attrs.id,
        summary: "add_routine #{attrs.id}: created from the dashboard, appended to #{path}"
      })

      {:noreply,
       socket
       |> assign(new_agent: %{open: false, preview: nil, error: nil, params: %{}})
       |> put_flash(:info, "#{attrs.id} added -- live now, scheduled at its next cron minute")
       |> refresh()}
    else
      {:error, reason} ->
        {:noreply, update(socket, :new_agent, &%{&1 | error: "refused: #{inspect(reason)}"})}
    end
  end

  def handle_event("filter", %{"tag" => tag}, socket) do
    # clicking the active tag clears the filter
    filter = if socket.assigns.tag_filter == tag, do: nil, else: tag
    {:noreply, socket |> assign(tag_filter: filter) |> refresh()}
  end

  # Form params (string-keyed, string-valued) into the WriteBack attrs
  # vocabulary -- the same conversions the TOML loader applies. Unknown
  # profiles come back as a message, not a crash.
  defp form_attrs(params) do
    id = String.trim(params["id"] || "")

    if id == "" do
      {:error, "id is required"}
    else
      attrs =
        %{id: id}
        |> form_put(params, "profile", &known_profile!/1)
        |> form_put(params, "cron")
        |> form_put(params, "repo")
        |> form_put(params, "working_dir")
        |> form_put(params, "workspace")
        |> form_put(params, "prompt")
        |> form_put(params, "tags", fn v ->
          v
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_atom/1)
        end)

      {:ok, attrs}
    end
  rescue
    ArgumentError -> {:error, "unknown profile #{inspect(params["profile"])}"}
  end

  # An unknown profile is one that is not a KEY in the profile map -- not
  # merely a string that fails to be an existing atom. Checking membership
  # (not just to_existing_atom raising) makes the guard robust to unrelated
  # atoms that happen to share the name. Either way it raises ArgumentError,
  # which the caller's rescue turns into the "unknown profile" message.
  defp known_profile!(value) do
    atom = String.to_existing_atom(value)
    if Map.has_key?(Custode.Routine.profiles(), atom), do: atom, else: raise(ArgumentError)
  end

  defp form_put(attrs, params, key, convert \\ & &1) do
    case String.trim(params[key] || "") do
      "" -> attrs
      value -> Map.put(attrs, String.to_existing_atom(key), convert.(value))
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:fleet} readouts={false}>
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <button
          :for={tag <- @all_tags}
          class={["badge cursor-pointer", (@tag_filter == tag && "badge-primary") || "badge-ghost"]}
          phx-click="filter"
          phx-value-tag={tag}
        >
          {tag}
        </button>
        <span class="ml-auto flex gap-2">
          <button
            :if={@any_pausable}
            class="btn btn-outline btn-error btn-xs"
            phx-click="pause_all"
            data-confirm="Pause every running agent?"
          >
            pause all
          </button>
          <button
            :if={@any_paused}
            class="btn btn-outline btn-success btn-xs"
            phx-click="resume_all"
          >
            resume all
          </button>
          <button class="btn btn-primary btn-xs" phx-click="new_agent_open">
            new agent
          </button>
        </span>
      </div>
      <.new_agent_modal new_agent={@new_agent} profiles={profile_names()} />
      <div class="flex flex-col gap-4 xl:flex-row-reverse xl:items-start">
        <.meta_rail
          tiles={@meta_tiles}
          fleet_today={@fleet_today}
          suggestions={@suggestions}
          suggestion_count={@suggestion_count}
          presence={@presence}
          rail_warnings={@rail_warnings}
          in_flight={@in_flight}
          away_digest={@away_digest}
        />
        <div class="min-w-0 flex-1">
          <p class="mb-2 text-xs text-base-content/40">grouped by attention</p>
          <div class="flex flex-col gap-6">
            <section :for={{group, members, rows} <- @attention_rows}>
              <div class="mb-2 flex flex-wrap items-baseline gap-2">
                <h2 class={[
                  "font-mono text-xs font-semibold uppercase tracking-wider",
                  group_tone(group)
                ]}>
                  {group_label(group)}
                </h2>
                <span class="font-mono text-xs text-base-content/40">{length(members)}</span>
                <span :if={group_note(group)} class="text-xs text-base-content/30">
                  {group_note(group)}
                </span>
                <button
                  :if={group == :quiet}
                  class="btn btn-ghost btn-xs ml-auto"
                  phx-click="toggle_quiet"
                >
                  {(@quiet_open && "collapse") || "expand"}
                </button>
              </div>
              <%!-- Quiet agents collapse to a line of names: page length should
                    track how much needs the operator, not how many agents
                    exist. Expandable, because "show me the one that has been
                    silent for a week" is a real question. --%>
              <div
                :if={group == :quiet && !@quiet_open}
                class="flex flex-wrap gap-x-3 gap-y-1 rounded-lg bg-base-200/40 px-3 py-2"
              >
                <.link
                  :for={{id, _tile} <- members}
                  navigate={"/agents/#{id}"}
                  class="font-mono text-xs text-base-content/40 hover:underline"
                >
                  {id}
                </.link>
              </div>
              <div
                :if={group != :quiet || @quiet_open}
                class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-2 2xl:grid-cols-3"
              >
                <%= for row <- rows do %>
                  <%= case row do %>
                    <% {:solo, {id, tile}} -> %>
                      <.tile id={id} tile={tile} />
                    <% {:group, repo, members} -> %>
                      <.tile_group repo={repo} members={members} />
                  <% end %>
                <% end %>
              </div>
            </section>
          </div>
        </div>
      </div>
    </.page>
    """
  end

  attr(:tiles, :list, required: true)
  attr(:fleet_today, :float, required: true)
  attr(:suggestions, :list, required: true)
  attr(:suggestion_count, :integer, default: 0)
  attr(:presence, :any, required: true)
  attr(:rail_warnings, :list, required: true)
  attr(:in_flight, :list, required: true)
  attr(:away_digest, :any, default: nil)

  # The caretaker's rail (#178). The meta agent is not a peer of the workers,
  # so activity sorting hid it exactly when it was quiet -- backwards for the
  # one agent whose job is watching the others. Here it gets a place rather
  # than a slot: a right-hand rail on wide screens, a strip above the grid on
  # narrow ones, outside the tag filter and outside the sort. The rail is also
  # where the fleet-level readouts live now (spend, who needs a human), which
  # is why it renders even with no :meta routine configured.
  defp meta_rail(assigns) do
    ~H"""
    <aside
      id="meta-rail"
      class="flex w-full shrink-0 flex-col gap-3 rounded-xl bg-base-200/40 p-3 xl:w-80"
    >
      <div class="flex items-baseline gap-2">
        <span class="text-xs uppercase tracking-wide text-base-content/40">caretaker</span>
        <button
          class={[
            "badge badge-xs cursor-pointer",
            (elem(@presence, 0) == :present && "badge-success") || "badge-ghost"
          ]}
          title="operator presence (#141): click to toggle; sweeps shape themselves to it"
          phx-click="toggle_presence"
        >
          {if elem(@presence, 0) == :present, do: "present", else: "away"}
        </button>
        <span class="ml-auto font-mono text-sm text-base-content/70">
          fleet today ${usd(@fleet_today)}
        </span>
      </div>
      <div
        :if={@away_digest}
        id="away-digest"
        class="rounded-lg border border-info/30 bg-info/5 p-2"
      >
        <div class="mb-1 flex items-center gap-2">
          <span class="text-xs font-semibold text-info">while you were away</span>
          <button class="btn btn-ghost btn-xs ml-auto" phx-click="dismiss_away_digest">
            dismiss
          </button>
        </div>
        <pre class="max-h-64 overflow-auto whitespace-pre-wrap text-xs text-base-content/80">{@away_digest}</pre>
      </div>
      <div :if={@in_flight != []} id="in-flight" class="flex flex-col gap-1">
        <span class="text-xs uppercase tracking-wide text-base-content/40">
          in flight ({length(@in_flight)})
        </span>
        <div
          :for={run <- @in_flight}
          class="flex items-center gap-2 rounded bg-base-100 px-2 py-1 text-xs shadow-sm"
        >
          <span class="inline-block h-1.5 w-1.5 shrink-0 animate-pulse rounded-full bg-info"></span>
          <.link navigate={"/agents/#{run.id}"} class="font-mono hover:underline">
            {run.id}
          </.link>
          <span class={["ml-auto font-mono", run.elapsed_s >= 300 && "text-warning"]}>
            {elapsed(run.elapsed_s)}
          </span>
        </div>
      </div>
      <.attention_chip wrap />
      <div
        :for={warning <- @rail_warnings}
        class="rounded-lg bg-warning/10 px-2 py-1 text-xs text-base-content/70"
      >
        <.link navigate={"/agents/#{warning.id}"} class="font-mono hover:underline">
          {warning.id}
        </.link>
        at <b>{warning.pct}%</b> of its daily rail -- resets at midnight {warning.tz}
      </div>
      <.caretaker_card :for={{id, tile} <- @tiles} id={id} tile={tile} />
      <p :if={@tiles == []} class="text-xs text-base-content/40">
        no :meta agent configured
      </p>
      <div :if={@suggestions != []} id="advisor-suggestions" class="flex flex-col gap-2">
        <div class="flex items-baseline gap-2">
          <span class="text-xs uppercase tracking-wide text-base-content/40">suggestions</span>
          <.link
            :if={@suggestion_count > length(@suggestions)}
            navigate="/suggestions"
            class="ml-auto text-xs text-primary hover:underline"
          >
            see all {@suggestion_count} &rarr;
          </.link>
        </div>
        <.suggestion_card :for={suggestion <- @suggestions} suggestion={suggestion} />
      </div>
    </aside>
    """
  end

  attr(:id, :string, required: true)
  attr(:tile, :map, required: true)

  # The caretaker as a rail RESIDENT, not a tile (operator, 2026-07-22):
  # a static element with its own layout leeway and an always-there prompt
  # box -- talking to the caretaker is the rail's whole point, so the
  # conversation entry never hides behind a click-through.
  defp caretaker_card(assigns) do
    ~H"""
    <div id={"tile-#{@id}"} class="rounded-lg bg-base-100 p-3 shadow-sm">
      <div class="flex items-center gap-2">
        <.link navigate={"/agents/#{@id}"} class="font-mono font-bold hover:underline">
          {@id}
        </.link>
        <.status_badge status={@tile.status} size="badge-sm" />
        <button class="btn btn-ghost btn-xs ml-auto" phx-click="beat" phx-value-id={@id}>
          beat
        </button>
      </div>
      <p :if={@tile.spend_today} class="mt-1 text-xs text-base-content/60">
        today <b>${usd(@tile.spend_today)}</b><span :if={@tile.budget}> / ${usd(@tile.budget)}</span>
      </p>
      <div :if={@tile.last} class="mt-2 rounded bg-base-200/60 p-2 text-xs">
        <div class="mb-1 flex items-center gap-2 text-base-content/50">
          <.event_badge entry={@tile.last} />
          <span class="font-mono"><.ago at={@tile.last["at"]} /></span>
        </div>
        <p class="line-clamp-3 text-base-content/80">{feed_text(@tile.last)}</p>
      </div>
      <form phx-submit="rail_prompt" class="mt-2">
        <input type="hidden" name="agent" value={@id} />
        <div class="flex items-end gap-1">
          <textarea
            name="text"
            rows="2"
            placeholder={"tell #{@id}..."}
            class="textarea textarea-sm min-h-0 flex-1 resize-y text-xs"
            autocomplete="off"
          ></textarea>
          <button class="btn btn-primary btn-xs">send</button>
        </div>
      </form>
    </div>
    """
  end

  attr(:suggestion, :map, required: true)

  # An advisor's standing proposal (#124/#125) as a card in the rail: the
  # change it wants, the evidence behind it, and how sure it is. The apply
  # button (#192) writes through WriteBack.update_routine -- the operator
  # clicking the dashboard is their own authority, same as the new-agent
  # form; agents proposing the same change still go through the caretaker's
  # gate. Only whitelisted fields render the button.
  defp suggestion_card(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-100 p-2 text-xs shadow">
      <div class="mb-1 flex items-center gap-2 text-base-content/50">
        <span class="badge badge-secondary badge-xs">suggestion</span>
        <span class="font-mono"><.ago at={@suggestion["at"]} /></span>
        <span class="ml-auto">{@suggestion["confidence"]}</span>
      </div>
      <p class="text-base-content/80">
        <.link navigate={"/agents/#{@suggestion["agent"]}"} class="font-mono hover:underline">
          {@suggestion["agent"]}
        </.link>
        <span class="font-mono">{@suggestion["field"]}</span>
        {@suggestion["current"]} &rarr; <b>{@suggestion["proposed"]}</b>
        <button
          :if={applicable_field?(@suggestion["field"])}
          class="btn btn-primary btn-xs ml-1"
          phx-click="apply_suggestion"
          phx-value-agent={@suggestion["agent"]}
          phx-value-field={@suggestion["field"]}
          phx-value-proposed={@suggestion["proposed"]}
        >
          apply
        </button>
        <button
          class="btn btn-ghost btn-xs"
          phx-click="dismiss_suggestion"
          phx-value-agent={@suggestion["agent"]}
          phx-value-field={@suggestion["field"]}
          phx-value-proposed={@suggestion["proposed"]}
        >
          dismiss
        </button>
      </p>
      <details :if={@suggestion["evidence"]} class="group mt-1 text-base-content/50">
        <summary
          class="line-clamp-3 cursor-pointer list-none group-open:line-clamp-none"
          title="click to expand the advisor's full reasoning"
        >
          {@suggestion["evidence"]}
        </summary>
      </details>
    </div>
    """
  end

  defp profile_names, do: Custode.Routine.profiles() |> Map.keys() |> Enum.sort()

  attr(:new_agent, :map, required: true)
  attr(:profiles, :list, required: true)

  # The new-agent modal (#75 slice 4): five assignment fields + overrides,
  # with the live preview being WriteBack's literal render -- what you see
  # is byte-for-byte what lands in routines.toml.
  defp new_agent_modal(assigns) do
    ~H"""
    <dialog :if={@new_agent.open} class="modal modal-open" id="new-agent-modal">
      <div class="modal-box max-w-2xl">
        <h3 class="mb-2 font-bold">new agent</h3>
        <form phx-change="new_agent_change" phx-submit="new_agent_create">
          <div class="grid grid-cols-2 gap-2">
            <label class="form-control">
              <span class="label-text text-xs">id (required)</span>
              <input
                name="routine[id]"
                value={@new_agent.params["id"]}
                class="input input-bordered input-sm"
                placeholder="my-worker"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">profile</span>
              <select name="routine[profile]" class="select select-bordered select-sm">
                <option value="">(none -- bespoke)</option>
                <option
                  :for={p <- @profiles}
                  value={p}
                  selected={to_string(p) == @new_agent.params["profile"]}
                >
                  {p}
                </option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text text-xs">repo (owner/name)</span>
              <input
                name="routine[repo]"
                value={@new_agent.params["repo"]}
                class="input input-bordered input-sm"
                placeholder="owner/repo"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">working_dir (absolute path)</span>
              <input
                name="routine[working_dir]"
                value={@new_agent.params["working_dir"]}
                class="input input-bordered input-sm"
                placeholder="/path/to/checkout"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">tags (comma separated)</span>
              <input
                name="routine[tags]"
                value={@new_agent.params["tags"]}
                class="input input-bordered input-sm"
                placeholder="rust, external"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">cron (profile default if blank)</span>
              <input
                name="routine[cron]"
                value={@new_agent.params["cron"]}
                class="input input-bordered input-sm"
                placeholder="@daily"
              />
            </label>
            <label class="form-control col-span-2">
              <span class="label-text text-xs">prompt (profile default if blank)</span>
              <input
                name="routine[prompt]"
                value={@new_agent.params["prompt"]}
                class="input input-bordered input-sm"
              />
            </label>
          </div>
          <div :if={@new_agent.error} class="mt-2 text-sm text-error">{@new_agent.error}</div>
          <div :if={@new_agent.preview} class="mt-2">
            <span class="text-xs text-base-content/50">
              this exact text lands in routines.toml:
            </span>
            <pre class="max-h-48 overflow-auto rounded bg-base-200 p-2 text-xs">{@new_agent.preview}</pre>
          </div>
          <div class="modal-action">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="new_agent_close">
              cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm" disabled={@new_agent.error != nil}>
              add agent
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="new_agent_close"></div>
    </dialog>
    """
  end

  attr(:repo, :string, required: true)
  attr(:members, :list, required: true)

  # A repo's agents grouped under one header (#243): the worker+steward pair
  # sits together as a single grid cell so the fleet page does not turn to
  # soup. A tile is still a phone number -- this groups them, it does not
  # merge them.
  defp tile_group(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/60 bg-base-200/20 p-2">
      <div class="mb-2 flex items-center gap-2 px-1">
        <.link navigate={"/repos"} class="font-mono text-xs font-semibold text-base-content/50 hover:underline">
          {@repo}
        </.link>
        <span class="text-xs text-base-content/30">{length(@members)} agents</span>
      </div>
      <div class="flex flex-col gap-2">
        <.tile :for={{id, tile} <- @members} id={id} tile={tile} />
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:tile, :map, required: true)

  defp tile(assigns) do
    ~H"""
    <div
      class={[
        "card shadow transition hover:shadow-lg",
        tile_cadence_bg(@tile.routine),
        tile_ring(@tile.state)
      ]}
      id={"tile-#{@id}"}
    >
      <div class="card-body gap-2 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <.link navigate={"/agents/#{@id}"} class="font-mono font-bold hover:underline">
            {@id}
          </.link>
          <.status_badge status={@tile.status} size="badge-sm" />
          <span
            :if={@tile.state == :paused && paused_reason(@tile.spend_today, @tile.budget)}
            class="text-xs text-error/80"
          >
            {paused_reason(@tile.spend_today, @tile.budget)}
          </span>
          <.link
            :if={@tile.failing_checks > 0}
            navigate={"/agents/#{@id}"}
            class="badge badge-error badge-sm gap-1 whitespace-nowrap"
            title="an open PR by this agent has failing checks"
          >
            {@tile.failing_checks} red
          </.link>
          <button
            :if={@tile.routine}
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="beat"
            phx-value-id={@id}
          >
            beat
          </button>
        </div>

        <%!-- The reason, as a sentence (#298). The status badge says what
              state the agent is in; this says why that state wants the
              operator, which for a red check or a reached rail was previously
              only inferable from a badge colour. --%>
        <p
          :if={@tile.signal.group == :needs_you}
          class="-mt-1 text-sm font-medium text-base-content/80"
        >
          {@tile.signal.headline}
        </p>

        <div
          :if={@tile.routine}
          class="-mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/40"
        >
          <span
            class="badge badge-outline badge-xs"
            title={Custode.Roles.summary(@tile.routine.role)}
          >
            {@tile.routine.role}
          </span>
          <span class="font-mono">{@tile.routine.cron}</span>
          <span :for={tag <- @tile.routine.tags} class="badge badge-ghost badge-xs">{tag}</span>
        </div>

        <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/60">
          <span :if={@tile.spend_today} class="flex items-center gap-2 whitespace-nowrap">
            today <b>${usd(@tile.spend_today)}</b><span :if={@tile.budget}> / ${usd(@tile.budget)}</span>
            <progress
              :if={@tile.budget}
              class={["progress w-14", budget_progress_class(@tile.spend_today, @tile.budget)]}
              value={@tile.spend_today}
              max={@tile.budget}
            >
            </progress>
          </span>
          <span
            :if={@tile.series && Enum.sum(@tile.series) > 0}
            class="text-base-content/30"
            title="spend, last 7 days"
          >
            <CustodeWeb.Charts.sparkline values={@tile.series} class="h-5 w-16" />
          </span>
          <span :if={@tile.open_todos > 0} class="whitespace-nowrap">{@tile.open_todos} todo(s)</span>
          <span :if={@tile.state == :offline} class="whitespace-nowrap">next beat starts it</span>
        </div>

        <div :if={@tile.last} class="rounded-lg bg-base-200/60 p-2 text-sm">
          <div class="mb-1 flex items-center gap-2 text-xs text-base-content/50">
            <.event_badge entry={@tile.last} />
            <span class="font-mono"><.ago at={@tile.last["at"]} /></span>
          </div>
          <p class="line-clamp-3 text-base-content/80">
            {@tile.last["summary"] || @tile.last["action"] || @tile.last["question"] ||
              @tile.last["kind"]}
          </p>
        </div>

        <div
          :if={match?({:awaiting_permission, _}, @tile.status)}
          class="flex items-center gap-2 rounded-lg bg-warning/15 p-2 text-sm"
        >
          <span class="line-clamp-2 flex-1">{elem(@tile.status, 1).description}</span>
          <button
            class="btn btn-success btn-xs"
            phx-click="approve"
            phx-value-id={@id}
            phx-value-action={elem(@tile.status, 1).id}
          >
            approve
          </button>
          <button
            class="btn btn-ghost btn-xs"
            phx-click="reject"
            phx-value-id={@id}
            phx-value-action={elem(@tile.status, 1).id}
          >
            reject
          </button>
        </div>

        <div
          :if={match?({:waiting_for_user, _}, @tile.status)}
          class="rounded-lg bg-accent/15 p-2 text-sm"
        >
          <span class="line-clamp-2">{elem(@tile.status, 1)}</span>
          <.link navigate={"/agents/#{@id}"} class="link link-accent text-xs">
            answer &rarr;
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # A ghost (a recently-ended ephemeral) is in neither the roster nor the
  # registry, so the fleet-wide resolver pass has no signal for it. Resolve
  # one from the little that is known, which lands it in :quiet.
  defp signal_for(signals, id, status, now) do
    Map.get_lazy(signals, id, fn ->
      Attention.resolve(%{id: id, state: state_of(status)}, %{now: now})
    end)
  end

  # Order tiles by their signals. Ranking is a property of a LIST, so rank the
  # signals once and index the tiles by where each one landed.
  defp rank_tiles(tiles) do
    position =
      tiles
      |> Enum.map(fn {_id, tile} -> tile.signal end)
      |> Attention.rank()
      |> Enum.with_index()
      |> Map.new(fn {signal, index} -> {signal.subject, index} end)

    Enum.sort_by(tiles, fn {id, _tile} -> Map.fetch!(position, id) end)
  end

  # The ranked tiles bucketed into the resolver's groups, in page order, empty
  # groups dropped. Repo grouping (#243) applies WITHIN a group rather than
  # across the whole grid: a repo's two agents stay adjacent while they share a
  # group, and separate correctly the moment one of them needs a human.
  defp attention_rows(tiles) do
    bucketed = Enum.group_by(tiles, fn {_id, tile} -> tile.signal.group end)

    for group <- Attention.groups(),
        members = Map.get(bucketed, group, []),
        members != [] do
      {group, members, group_tiles(members)}
    end
  end

  defp group_label(:needs_you), do: "needs you"
  defp group_label(:working), do: "working now"
  defp group_label(:scheduled), do: "on schedule"
  defp group_label(:quiet), do: "quiet"

  defp group_tone(:needs_you), do: "text-warning"
  defp group_tone(:working), do: "text-success"
  defp group_tone(_group), do: "text-base-content/40"

  defp group_note(:scheduled), do: "nothing wanted"
  defp group_note(:quiet), do: "all green, no work found in window"
  defp group_note(_group), do: nil

  # Fold the ranked tiles into rows (#243): a repo with two or more
  # agents (the worker+steward pressure design/006 names) becomes ONE grouped
  # row so its agents sit adjacent under a repo header; everything else --
  # single-agent repos, non-repo routines, ghosts -- stays a solo tile exactly
  # as before. A group lands at its most-active member's position (the tiles
  # come in pre-sorted), so activity ordering across groups is preserved and
  # the pair stays together inside.
  defp group_tiles(tiles) do
    grouped =
      tiles
      |> Enum.frequencies_by(&tile_repo/1)
      |> Enum.filter(fn {repo, count} -> is_binary(repo) and count >= 2 end)
      |> Enum.map(fn {repo, _count} -> repo end)
      |> MapSet.new()

    {rows, _emitted} =
      Enum.reduce(tiles, {[], MapSet.new()}, fn {_id, _tile} = entry, {rows, emitted} ->
        repo = tile_repo(entry)

        cond do
          not MapSet.member?(grouped, repo) ->
            {[{:solo, entry} | rows], emitted}

          MapSet.member?(emitted, repo) ->
            {rows, emitted}

          true ->
            members = Enum.filter(tiles, &(tile_repo(&1) == repo))
            {[{:group, repo, members} | rows], MapSet.put(emitted, repo)}
        end
      end)

    Enum.reverse(rows)
  end

  defp tile_repo({_id, %{routine: %{repo: repo}}}) when is_binary(repo), do: repo
  defp tile_repo(_entry), do: nil

  # the "while you were away" digest (#263): built only on return from a real
  # absence and only until dismissed for the session -- so it greets the
  # operator once and stays quiet on refreshes
  defp away_digest(socket) do
    if socket.assigns[:away_dismissed] do
      nil
    else
      case Custode.Presence.away_window() do
        {:since, since} -> since |> Custode.Digest.build_since() |> Custode.Digest.to_markdown()
        :none -> nil
      end
    end
  end

  defp refresh(socket) do
    routines = Routine.all()
    routine_ids = Enum.map(routines, & &1.id)
    running = Agent.list() |> Map.new()
    all_ids = Enum.uniq(routine_ids ++ Map.keys(running))
    routines_by_id = Map.new(routines, &{&1.id, &1})

    series_by_agent = Custode.Metrics.spend_series_by_agent(7)
    spend_by_agent = Custode.SpendLedger.today_by_agent()

    # One resolver pass for the fleet (#298). The page no longer decides what
    # needs a human or in what order; it reads Custode.Attention and renders
    # the answer. Ghosts are not in the roster or the registry, so they get a
    # signal resolved from what little is known about them (which is :quiet).
    signals = Attention.Fleet.signals_by_id()
    now = DateTime.utc_now()

    tiles =
      for id <- all_ids do
        status = Map.get(running, id, :offline)
        routine = routines_by_id[id]

        {id,
         %{
           status: status,
           state: state_of(status),
           signal: signal_for(signals, id, status, now),
           routine: routine,
           budget: routine && routine.daily_budget_usd,
           spend_today: Map.get(spend_by_agent, id, 0.0),
           open_todos: length(Custode.Notebook.todos(id)),
           series: Map.get(series_by_agent, id),
           last: Custode.Feed.last_message(id, needs_attention?(status)),
           failing_checks: failing_checks(routine)
         }}
      end

    # ghost tiles (#11): recently-ended ephemerals whose trail persists --
    # seen in the feed within the window, not running, not a routine
    ghost_ids =
      Custode.Feed.recent_agents(Application.get_env(:custode, :ghost_window_s, 3_600)) --
        (all_ids ++ routine_ids)

    ghosts =
      for id <- ghost_ids do
        {id,
         %{
           status: :ended,
           state: :ended,
           signal: signal_for(signals, id, :ended, now),
           routine: nil,
           budget: nil,
           spend_today: Map.get(spend_by_agent, id, 0.0),
           open_todos: 0,
           series: nil,
           last: Custode.Feed.last_for(id),
           failing_checks: 0
         }}
      end

    # :meta tiles leave the grid entirely for the rail (#178) -- no filter, no
    # sort, so a quiet caretaker stays where the operator left it
    {meta_tiles, worker_tiles} =
      Enum.split_with(tiles ++ ghosts, fn {_id, tile} -> meta?(tile) end)

    # Ranked by the resolver (#298): group, then kind precedence, then
    # urgency, then oldest-first. The page used to sort itself, binary
    # attention ahead of recency, which put the oldest unanswered question
    # last among the agents that needed one.
    tiles =
      worker_tiles
      |> filter_tiles(socket.assigns[:tag_filter])
      |> rank_tiles()

    # the chips filter the grid, so they come from the routines the grid holds
    all_tags =
      routines
      |> Enum.reject(&meta_routine?/1)
      |> Enum.flat_map(& &1.tags)
      |> Enum.uniq()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    states = Enum.map(running, fn {_id, status} -> state_of(status) end)
    standing_suggestions = Custode.Suggestions.standing()

    assign(socket,
      tiles: tiles,
      attention_rows: attention_rows(tiles),
      meta_tiles: Enum.sort_by(meta_tiles, fn {id, _tile} -> id end),
      suggestions: Enum.take(standing_suggestions, @suggestion_limit),
      suggestion_count: length(standing_suggestions),
      presence: Custode.Presence.status(),
      away_digest: away_digest(socket),
      in_flight: in_flight(),
      rail_warnings: rail_warnings(tiles ++ meta_tiles),
      all_tags: all_tags,
      any_pausable: Enum.any?(states, &(&1 not in [:paused, :offline])),
      any_paused: :paused in states,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  # the rail shows the top few (Custode.Suggestions holds the standing list +
  # apply); the full list lives on /suggestions (#284)
  defp applicable_field?(field), do: Custode.Suggestions.applicable_field?(field)

  # Rank-1 promotion (#31): failing checks on an agent's own open PR were
  # the quietest signal on the page (a dot inside a panel two clicks away).
  # Reads the cached overview only -- the cache refreshes on its own cadence
  # and broadcasts, so tiles cost no extra API calls.
  defp failing_checks(%{repo: repo}) when is_binary(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} ->
        Enum.count(overview.open_prs.items, &(&1[:checks] in ["FAILURE", "ERROR"]))

      :loading ->
        0
    end
  end

  defp failing_checks(_routine), do: 0

  # Threshold banners (#211, the desktop-app cue): say an agent is
  # APPROACHING its rail before the rail says it out loud by pausing.
  # 80% and rising, not yet paused (a paused tile already reads 'daily
  # rail'); the reset time names the configured timezone because that is
  # the day the rails roll on (#164).
  @rail_warning_pct 0.8

  # What is executing right now (#211), longest-running first so a stuck
  # turn floats to the top. Elapsed is computed at render, and the 5s tick
  # keeps it climbing when nothing else re-renders the page.
  # compact elapsed: "12s", "3m", "1h04" -- a turn running past a few minutes
  # is the signal the panel exists to surface
  defp elapsed(seconds) when seconds < 60, do: "#{seconds}s"
  defp elapsed(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  defp elapsed(seconds) do
    "#{div(seconds, 3600)}h#{seconds |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp in_flight do
    now = DateTime.utc_now()

    Custode.RunClock.running()
    |> Enum.map(fn {id, started_at} ->
      %{id: id, elapsed_s: max(DateTime.diff(now, started_at), 0)}
    end)
    |> Enum.sort_by(& &1.elapsed_s, :desc)
  end

  defp rail_warnings(tiles) do
    tz = Application.get_env(:custode, :timezone, "Etc/UTC")

    tiles
    |> Enum.filter(fn {_id, tile} ->
      is_number(tile.budget) and tile.budget > 0 and is_number(tile.spend_today) and
        tile.spend_today / tile.budget >= @rail_warning_pct and tile.state != :paused
    end)
    |> Enum.map(fn {id, tile} ->
      %{id: id, pct: round(tile.spend_today / tile.budget * 100), tz: tz}
    end)
    |> Enum.sort_by(& &1.pct, :desc)
  end

  # sub-agents and ghosts carry no routine, so they are never meta
  defp meta?(%{routine: nil}), do: false
  defp meta?(%{routine: routine}), do: meta_routine?(routine)

  defp meta_routine?(routine), do: :meta in routine.tags

  # non-routine agents (sub-agents) have no tags and hide under any filter
  defp filter_tiles(tiles, nil), do: tiles

  defp filter_tiles(tiles, tag) do
    Enum.filter(tiles, fn {_id, tile} ->
      tile.routine != nil and tag in Enum.map(tile.routine.tags, &to_string/1)
    end)
  end

  # sortable key for "most recent activity, newest first": active agents
  # (present timestamp) sort ahead of never-active ones, and within the
  # active set a negated unix stamp puts the newest first under an ascending
  # sort. nil stamps share a constant, leaving id as the tiebreak.

  # Quiet-cadence roles (the steward, watchers, tutor) get a subtler card so a
  # loud worker and a mostly-green @daily steward read differently (#243). The
  # cadence comes from the role registry, not the view.
  defp tile_cadence_bg(%{role: role}) do
    if Custode.Roles.cadence(role) == :quiet, do: "bg-base-100/60", else: "bg-base-100"
  end

  defp tile_cadence_bg(_no_routine), do: "bg-base-100"

  defp tile_ring(:ended), do: "opacity-60"
  defp tile_ring(:awaiting_permission), do: "ring-2 ring-warning"
  defp tile_ring(:waiting_for_user), do: "ring-2 ring-accent"
  defp tile_ring(:paused), do: "ring-2 ring-error"
  defp tile_ring(_state), do: nil

  defp state_of(status), do: Custode.state_of(status)
end
