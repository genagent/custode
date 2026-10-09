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

    {:ok,
     assign(socket,
       dashboard: nil,
       selected_id: nil,
       agreements_before: nil,
       error: nil,
       recovery: nil,
       refresh_pending: false
     )}
  end

  # The agreement cursor lives in the URL, so a reload or refresh keeps the
  # same page and a patch to the owner or home without it returns to newest.
  # A present but empty or malformed value is passed on and reported, never
  # read as the newest page.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(selected_id: params["id"], agreements_before: Map.get(params, "agreements_before"))
     |> refresh()}
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
          <.link :if={@recovery} patch={@recovery} class="link">Newest agreements</.link>
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
    %{selected_id: id, agreements_before: before} = socket.assigns
    opts = if id, do: [routine_id: id], else: []
    opts = if is_nil(before), do: opts, else: [{:agreement_before, before} | opts]

    case WorkstreamDashboard.read(@operator, opts) do
      {:ok, dashboard} ->
        assign(socket, dashboard: dashboard, error: nil, recovery: nil)

      {:error, reason} ->
        assign(socket,
          dashboard: nil,
          error: error_text(reason, id, before),
          recovery: recovery(reason, id, before)
        )
    end
  end

  defp error_text(:unknown_routine, _id, _before), do: "This owner is not configured."

  defp error_text(:invalid_options, nil, before) when not is_nil(before),
    do: "Agreement pages apply to one workstream. Open a workstream to page its agreements."

  defp error_text(:invalid_arguments, _id, before) when not is_nil(before),
    do: "This agreement page link is malformed. It does not name an agreement."

  defp error_text(:invalid_cursor, _id, before) when not is_nil(before),
    do:
      "This agreement page link does not match a current agreement for this owner. " <>
        "It may have been removed or belong to another owner."

  defp error_text(_reason, _id, _before),
    do: "The current workstream records could not be loaded. The Console remains available."

  defp recovery(reason, id, before)
       when reason in [:invalid_arguments, :invalid_cursor] and is_binary(id) and
              not is_nil(before),
       do: "/workstreams/#{URI.encode(id, &URI.char_unreserved?/1)}"

  defp recovery(_reason, _id, _before), do: nil
end
