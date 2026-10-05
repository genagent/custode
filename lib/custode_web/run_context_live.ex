defmodule CustodeWeb.RunContextLive do
  @moduledoc "Operator inspection of immutable adapter context; opening never resumes a turn."
  use Phoenix.LiveView
  import CustodeWeb.Components, only: [page: 1]
  alias Custode.ReturnViews
  alias CustodeWeb.AttentionSnapshot
  @human %{kind: :operator, id: "dashboard"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    {:ok,
     socket
     |> AttentionSnapshot.refresh()
     |> assign(
       fleet_today: Custode.SpendLedger.fleet_today(),
       agent_id: nil,
       receipts: [],
       receipt: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"agent_id" => agent} = params, _uri, socket) do
    with {:ok, result} <-
           ReturnViews.invoke(@human, %{"action" => "run_contexts", "agent_id" => agent}),
         {:ok, receipt} <- selected(params["receipt"], result["receipts"]) do
      {:noreply,
       assign(socket, agent_id: agent, receipts: result["receipts"], receipt: receipt, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, agent_id: agent, receipts: [], receipt: nil, error: reason)}
    end
  end

  defp selected(nil, _records), do: {:ok, nil}

  defp selected(id, records) do
    if Enum.any?(records, &(&1["receipt_id"] == id)),
      do: ReturnViews.invoke(@human, %{"action" => "run_context", "receipt_id" => id}),
      else: {:error, "Receipt is not in this agent's recent context list."}
  end

  @impl true
  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl true
  def render(assigns) do
    ~H"""
    <.page active={:console} fleet_today={@fleet_today} attention_signals={@attention_signals}>
      <section class="mx-auto max-w-4xl space-y-4">
        <h1 class="text-xl font-semibold">Run context: {@agent_id}</h1>
        <.link navigate={"/agents/" <> URI.encode_www_form(@agent_id) <> "/conversation"} class="link text-sm">Return to conversation</.link>
        <p class="text-sm text-base-content/70">These are inline arguments observed as an adapter starts a durable execution. Provider receipt, model use, hidden native instructions and file-based context remain unknown. Opening this view never starts work.</p>
        <p :if={@error} role="status" class="text-warning">{@error}</p>
        <p :if={@receipts == []} class="text-base-content/60">No retained adapter-entry context. Earlier turns are not reconstructed from current files.</p>
        <ul id="run-context-list" class="space-y-2">
          <li :for={row <- @receipts} class="rounded-box border border-base-300 p-3">
            <.link navigate={"/contexts/" <> URI.encode_www_form(@agent_id) <> "?receipt=" <> URI.encode_www_form(row["receipt_id"])} class="link font-mono text-sm">{row["recorded_at"]} · {row["execution"]["provider"]} · turn {row["execution"]["agent_turn_id"]}</.link>
            <p class="text-xs text-base-content/60">{row["state"]} · payload {row["payload_state"]}</p>
          </li>
        </ul>
        <article :if={@receipt} id="run-context-detail" class="card border border-base-300 bg-base-100">
          <div class="card-body">
            <h2 class="card-title">Exact adapter-entry context</h2>
            <p class="text-sm">{@receipt["payload_state"]}; provider receipt and use unknown.</p>
            <p :if={@receipt["exact_inline_layers"] == nil} class="text-sm">Payload is unavailable. Current files are not substituted.</p>
            <section :if={@receipt["native_observation"]} id="run-context-native" class="space-y-1">
              <h3 class="font-semibold">Native session observation</h3>
              <p class="font-mono text-sm break-all">{@receipt["native_observation"]["provider_session_id"]}</p>
              <p class="text-sm">{@receipt["native_observation"]["source"]} · {@receipt["native_observation"]["observed_at"]}</p>
              <p class="text-sm text-base-content/70">The owning engine accepted this native handle for the exact captured attempt. Context receipt and model use remain unknown.</p>
            </section>
            <section :if={@receipt["assignment_execution"]} id="run-context-documents" class="space-y-2">
              <h3 class="font-semibold">Document retrieval receipts</h3>
              <p class="text-sm">The host credential was available for this execution. Each separate receipt distinguishes prepared text from server-emitted text; model receipt and use remain unknown.</p>
              <p :if={@receipt["document_retrievals"]["receipts"] == []} class="text-sm text-base-content/60">No retained document retrieval observed for this launch.</p>
              <ul><li :for={row <- @receipt["document_retrievals"]["receipts"]}>
                <.link navigate={"/subjects/" <> URI.encode_www_form(row["root_id"]) <> "?receipt=" <> URI.encode_www_form(row["receipt_id"])} class="link text-sm">{row["path"]} · {row["state"]} · revision {String.slice(row["revision"] || "", 0, 12)}</.link>
              </li></ul>
              <p :if={@receipt["document_retrievals"]["has_more"]} class="text-sm">The bounded receipt list may have more retained entries.</p>
            </section>
            <details id="run-context-execution"><summary class="cursor-pointer font-semibold">Captured execution and layer manifest</summary><pre class="max-h-96 overflow-auto whitespace-pre-wrap text-xs">{Jason.encode!(Map.delete(@receipt, "exact_inline_layers"), pretty: true)}</pre></details>
            <details :if={@receipt["exact_inline_layers"]} id="run-context-inline"><summary class="cursor-pointer font-semibold">Exact retained inline instructions and prompt</summary><pre class="max-h-96 overflow-auto whitespace-pre-wrap text-sm">{Jason.encode!(@receipt["exact_inline_layers"], pretty: true)}</pre></details>
          </div>
        </article>
      </section>
    </.page>
    """
  end
end
