defmodule CustodeWeb.WorkstreamsLive do
  @moduledoc "Workstream home and detail over shared operator projections and actions."

  use Phoenix.LiveView

  alias Custode.Operator.Actions
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
       refresh_pending: false,
       answer_forms: %{},
       answer_feedback: nil
     )}
  end

  # The agreement cursor lives in the URL, so a reload or refresh keeps the
  # same page and a patch to the owner or home without it returns to newest.
  # A present but empty or malformed value is passed on and reported, never
  # read as the newest page.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    socket =
      if params["id"] == socket.assigns.selected_id,
        do: socket,
        else: assign(socket, :answer_feedback, nil)

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
  def handle_event(event, params, socket)
      when event in ["draft_answer", "answer_ask", "discard_answer"] do
    key = {params["owner"], params["ask_id"]}

    # Binding is view selection only. Text and record-state rules belong to
    # Actions/Asks, including the atomic close when another view wins.
    case socket.assigns.answer_forms[key] do
      nil ->
        {:noreply,
         assign(socket, :answer_feedback, "This question was not displayed for this owner.")}

      form when elem(key, 0) == socket.assigns.selected_id ->
        case event do
          "discard_answer" ->
            {:noreply,
             socket
             |> assign(:answer_forms, Map.delete(socket.assigns.answer_forms, key))
             |> assign(:answer_feedback, "Draft discarded for question ##{form.decision.id}.")
             |> refresh()}

          "draft_answer" ->
            form = %{form | text: params["text"] || "", error: nil}

            {:noreply,
             socket
             |> assign(:answer_forms, Map.put(socket.assigns.answer_forms, key, form))
             |> bind_answers(socket.assigns.dashboard)}

          "answer_ask" ->
            form = %{form | text: params["text"] || ""}
            {:noreply, answer(socket, key, form)}
        end

      _form ->
        {:noreply,
         assign(socket, :answer_feedback, "This question was not displayed for this owner.")}
    end
  end

  defp answer(socket, key, form) do
    case Actions.answer_ask(form.decision.id, form.text) do
      :ok ->
        socket
        |> assign(:answer_forms, Map.delete(socket.assigns.answer_forms, key))
        |> assign(:answer_feedback, "Answer sent for question ##{form.decision.id}.")
        |> refresh()

      {:error, reason} ->
        socket
        |> assign(
          :answer_forms,
          Map.put(socket.assigns.answer_forms, key, %{form | error: reason})
        )
        |> assign(:answer_feedback, nil)
        |> refresh()
    end
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
        answer_forms={@answer_forms}
        answer_feedback={@answer_feedback}
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
        socket
        |> assign(dashboard: dashboard, error: nil, recovery: nil)
        |> bind_answers(dashboard)

      {:error, reason} ->
        assign(socket,
          dashboard: nil,
          error: error_text(reason, id, before),
          recovery: recovery(reason, id, before)
        )
        |> bind_answers(nil)
    end
  end

  defp bind_answers(socket, dashboard) do
    decisions =
      case {dashboard, socket.assigns.selected_id} do
        {%{workstreams: [workstream | _]}, id} when is_binary(id) -> workstream.decisions.asks
        _ -> []
      end

    displayed = MapSet.new(decisions, &{&1.owner, to_string(&1.id)})

    forms =
      Map.filter(socket.assigns.answer_forms, fn {key, form} ->
        MapSet.member?(displayed, key) or String.trim(form.text) != "" or not is_nil(form.error)
      end)

    forms =
      Enum.reduce(decisions, forms, fn decision, forms ->
        Map.put_new(forms, {decision.owner, to_string(decision.id)}, %{
          decision: decision,
          text: "",
          error: nil
        })
      end)

    assign(socket, :answer_forms, forms)
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
