defmodule CustodeWeb.SuggestionsLive do
  @moduledoc """
  The suggestions page (#284): every standing advisor suggestion, with room
  for the full evidence text -- the rail only shows the top few. The advisors
  (#124/#125/#262) record `advisor_suggestion` feed entries; `Custode.Suggestions`
  holds the standing/deduped list and the apply path, shared with the fleet
  rail so both read one source.
  """

  use Phoenix.LiveView

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  alias Custode.Advisors.Record
  alias Custode.Operator.Actions
  alias Custode.Suggestions.Outcome

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, socket |> assign(dismissing: nil) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl Phoenix.LiveView
  def handle_event("apply_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    case Actions.apply_suggestion(id, field, proposed, via: :liveview) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "apply refused: #{inspect(reason)}")}
    end
  end

  # Which card is asking for a reason. View state, so it lives in the socket.
  @impl Phoenix.LiveView
  def handle_event("dismiss_open", %{"agent" => id, "field" => field}, socket) do
    {:noreply, assign(socket, dismissing: {id, field})}
  end

  def handle_event("dismiss_cancel", _params, socket) do
    {:noreply, assign(socket, dismissing: nil)}
  end

  def handle_event("dismiss_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    {:ok, message} =
      Actions.dismiss_suggestion(id, field, proposed, params["reason"], via: :liveview)

    {:noreply, socket |> assign(dismissing: nil) |> put_flash(:info, message) |> refresh()}
  end

  defp dismissing?(nil, _suggestion), do: false

  defp dismissing?({id, field}, suggestion),
    do: suggestion["agent"] == id and suggestion["field"] == field

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:suggestions}>
      <.page_header
        title="Suggestions"
        summary={"#{length(@suggestions)} standing #{if length(@suggestions) == 1, do: "suggestion", else: "suggestions"} from the fleet's advisors."}
      />
      <p class="mb-4 text-sm text-base-content/70">
        Applying a suggestion writes through the roster and takes effect at the next sweep; the advisor stops re-proposing it.
      </p>

      <p :if={@suggestions == []} class="text-sm text-base-content/40">
        no standing suggestions -- the advisors have nothing to propose right now.
      </p>

      <ul :if={@suggestions != []} aria-label="Standing suggestions" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={s <- @suggestions} class="p-4">
          <div class="mb-1 flex items-center gap-2 text-xs text-base-content/50">
            <span class="badge badge-secondary badge-xs">{s["advisor"]}</span>
            <span class="font-mono"><.ago at={s["at"]} /></span>
            <span class="ml-auto">{s["confidence"]}</span>
          </div>
          <p class="text-sm">
            <.link navigate={"/console/#{s["agent"]}"} class="font-mono font-semibold hover:underline">
              {s["agent"]}
            </.link>
            <span class="font-mono text-base-content/70">{s["field"]}</span>
            <span class="text-base-content/70">{s["current"]}</span>
            &rarr; <b>{s["proposed"]}</b>
            <.action_button
              :if={Custode.Suggestions.applicable_field?(s["field"])}
              variant={:primary} class="ml-1"
              phx-click="apply_suggestion"
              phx-value-agent={s["agent"]}
              phx-value-field={s["field"]}
              phx-value-proposed={s["proposed"]}
            >
              Apply
            </.action_button>
            <.action_button
              :if={!dismissing?(@dismissing, s)}
              variant={:quiet}
              phx-click="dismiss_open"
              phx-value-agent={s["agent"]}
              phx-value-field={s["field"]}
            >
              Dismiss
            </.action_button>
          </p>

          <%!-- The reasons appear on click rather than sitting on every card
                (#303): three buttons per suggestion would make the page read
                as a form, and the common path is still one click. --%>
          <div :if={dismissing?(@dismissing, s)} class="mt-2 flex flex-wrap items-center gap-2">
            <span class="text-xs text-base-content/50">Reason for dismissal</span>
            <.action_button
              :for={{reason, label} <- Custode.Suggestions.dismiss_reasons()}
              variant={:secondary}
              phx-click="dismiss_suggestion"
              phx-value-agent={s["agent"]}
              phx-value-field={s["field"]}
              phx-value-proposed={s["proposed"]}
              phx-value-reason={reason}
            >
              {String.capitalize(label)}
            </.action_button>
            <.action_button variant={:quiet} phx-click="dismiss_cancel">Cancel</.action_button>
          </div>
          <p :if={s["evidence"]} class="mt-2 text-sm text-base-content/60">{s["evidence"]}</p>
        </li>
      </ul>
      <%!-- Which advisor is worth listening to (#304). The decisions below
            are individual outcomes; this is the reputation they add up to. --%>
      <h2 :if={@advisors != []} class="mt-8 mb-2 text-sm font-semibold text-base-content/70">
        advisors
      </h2>
      <ul :if={@advisors != []} class="flex flex-col divide-y divide-base-300/60 text-sm">
        <li :for={a <- @advisors} class="flex flex-wrap items-baseline gap-x-2 py-2">
          <span class="font-mono font-semibold">{a.advisor}</span>
          <span :if={a.grade == :judgment} class="badge badge-ghost badge-xs">judgment</span>
          <span :if={a.standing > 0} class="text-xs text-base-content/50">
            {a.standing} standing
          </span>
          <span class="ml-auto text-xs text-base-content/50">{Record.describe(a)}</span>
        </li>
      </ul>

      <%!-- The record of judgment (#303). A suggestion used to have two
            states, standing and gone, so the system never learned whether
            the advice was any good and neither did the advisor. --%>
      <h2 :if={@decisions != []} class="mt-8 mb-2 text-sm font-semibold text-base-content/70">
        decisions
      </h2>
      <ul :if={@decisions != []} class="flex flex-col divide-y divide-base-300/60 text-sm">
        <li :for={d <- @decisions} class="flex flex-wrap items-baseline gap-x-2 py-2">
          <.status_token tone={decision_tone(d)}>{d.status}</.status_token>
          <.link navigate={"/console/#{d.agent}"} class="font-mono hover:underline">{d.agent}</.link>
          <span class="font-mono text-base-content/60">{d.field}</span>
          <span class="text-base-content/70">&rarr; {d.proposed}</span>
          <span class="ml-auto text-xs text-base-content/50">
            {Outcome.describe(d)}
          </span>
        </li>
      </ul>
    </.page>
    """
  end

  # Only a reverted change is a bad outcome. Observing is not yet an answer,
  # and superseded is not a failure -- just not a lesson.
  defp decision_tone(%{status: :reverted}), do: :error
  defp decision_tone(%{status: :settled}), do: :success
  defp decision_tone(%{status: :observing}), do: :info
  defp decision_tone(_other), do: :neutral

  defp refresh(socket) do
    socket = AttentionSnapshot.refresh(socket)

    assign(socket,
      suggestions: Custode.Suggestions.standing(),
      decisions: Outcome.history(),
      advisors: Record.all(),
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end
end
