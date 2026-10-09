defmodule CustodeWeb.WorkstreamsLive do
  @moduledoc "Read-only workstream home and detail over shared operator projections."

  use Phoenix.LiveView

  alias Custode.WorkstreamDashboard
  alias CustodeWeb.{AttentionSnapshot, WorkstreamComponents}

  import CustodeWeb.Components, only: [page: 1]

  @operator %{kind: :operator, id: "liveview"}
  @refresh_interval 30_000
  @refresh_delay 1_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Custode.PubSubBridge.subscribe()
      Process.send_after(self(), :refresh_workstreams, @refresh_interval)
    end

    {:ok, assign(socket, dashboard: nil, selected_id: nil, error: nil, refresh_pending: false)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:selected_id, params["id"]) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh_workstreams, socket) do
    Process.send_after(self(), :refresh_workstreams, @refresh_interval)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(:refresh_pending, false) |> refresh()}
  end

  def handle_info({:work_agreement_changed, _owner}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(message, socket) do
    {:noreply,
     if(AttentionSnapshot.relevant?(message), do: schedule_refresh(socket), else: socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={0} readouts={false} active={:dashboard}>
      <section :if={@error} id="workstream-error" class="mx-auto max-w-3xl">
        <h1 class="text-2xl font-bold">Workstream unavailable</h1>
        <p role="alert" class="mt-3 text-base-content/70">{@error}</p>
        <nav aria-label="Recovery" class="mt-4 flex flex-wrap gap-4 text-sm">
          <.link patch="/" class="link">Dashboard</.link>
          <.link navigate="/console" class="link">Open Console</.link>
        </nav>
      </section>
      <WorkstreamComponents.home :if={@dashboard && !@selected_id} dashboard={@dashboard} />
      <WorkstreamComponents.detail
        :if={@dashboard && @selected_id}
        workstream={List.first(@dashboard.workstreams)}
        dashboard={@dashboard}
      />
    </.page>
    """
  end

  defp schedule_refresh(%{assigns: %{refresh_pending: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh, @refresh_delay)
    assign(socket, :refresh_pending, true)
  end

  defp refresh(socket) do
    opts = if socket.assigns.selected_id, do: [routine_id: socket.assigns.selected_id], else: []

    case WorkstreamDashboard.read(@operator, opts) do
      {:ok, dashboard} ->
        assign(socket, dashboard: dashboard, error: nil)

      {:error, :unknown_routine} ->
        assign(socket, dashboard: nil, error: "This owner is not configured.")

      {:error, _reason} ->
        assign(socket,
          dashboard: nil,
          error:
            "The current workstream records could not be loaded. The Console remains available."
        )
    end
  end
end
