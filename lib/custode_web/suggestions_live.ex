defmodule CustodeWeb.SuggestionsLive do
  @moduledoc """
  The suggestions page (#284): every standing advisor suggestion, with room
  for the full evidence text -- the rail only shows the top few. The advisors
  (#124/#125/#262) record `advisor_suggestion` feed entries; `Custode.Suggestions`
  holds the standing/deduped list and the apply path, shared with the fleet
  rail so both read one source.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl Phoenix.LiveView
  def handle_event("apply_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    case Custode.Suggestions.apply(id, field, proposed) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "apply refused: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("dismiss_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params
    {:ok, message} = Custode.Suggestions.dismiss(id, field, proposed)
    {:noreply, socket |> put_flash(:info, message) |> refresh()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:suggestions}>
      <p class="mb-4 text-sm text-base-content/50">
        {length(@suggestions)} standing suggestion(s) from the fleet's advisors. Applying one
        writes through the roster and takes effect at the next sweep; the advisor stops re-proposing it.
      </p>

      <p :if={@suggestions == []} class="text-sm text-base-content/40">
        no standing suggestions -- the advisors have nothing to propose right now.
      </p>

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
        <div :for={s <- @suggestions} class="rounded-lg bg-base-100 p-3 shadow">
          <div class="mb-1 flex items-center gap-2 text-xs text-base-content/50">
            <span class="badge badge-secondary badge-xs">{s["advisor"]}</span>
            <span class="font-mono"><.ago at={s["at"]} /></span>
            <span class="ml-auto">{s["confidence"]}</span>
          </div>
          <p class="text-sm">
            <.link navigate={"/agents/#{s["agent"]}"} class="font-mono font-semibold hover:underline">
              {s["agent"]}
            </.link>
            <span class="font-mono text-base-content/70">{s["field"]}</span>
            <span class="text-base-content/70">{s["current"]}</span>
            &rarr; <b>{s["proposed"]}</b>
            <button
              :if={Custode.Suggestions.applicable_field?(s["field"])}
              class="btn btn-primary btn-xs ml-1"
              phx-click="apply_suggestion"
              phx-value-agent={s["agent"]}
              phx-value-field={s["field"]}
              phx-value-proposed={s["proposed"]}
            >
              apply
            </button>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="dismiss_suggestion"
              phx-value-agent={s["agent"]}
              phx-value-field={s["field"]}
              phx-value-proposed={s["proposed"]}
            >
              dismiss
            </button>
          </p>
          <p :if={s["evidence"]} class="mt-2 text-sm text-base-content/60">{s["evidence"]}</p>
        </div>
      </div>
    </.page>
    """
  end

  defp refresh(socket) do
    assign(socket,
      suggestions: Custode.Suggestions.standing(),
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end
end
