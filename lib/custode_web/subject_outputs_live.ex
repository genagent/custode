defmodule CustodeWeb.SubjectOutputsLive do
  @moduledoc "Read current outputs separately from retained server-emission receipts; never resume an agent."
  use Phoenix.LiveView
  import CustodeWeb.Components, only: [page: 1]
  alias Custode.{ReturnViews, SubjectDocuments}
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
       root_id: nil,
       roots: [],
       outputs: [],
       document: nil,
       contexts: [],
       receipt: nil,
       error: nil,
       feedback_id: Ecto.UUID.generate()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    root = params["root_id"]
    {:ok, roots} = SubjectDocuments.invoke(@human, %{"action" => "roots"})

    socket =
      assign(socket,
        roots: roots["roots"],
        root_id: root,
        error: nil,
        document: nil,
        receipt: nil
      )

    {:noreply, load(socket, params)}
  end

  defp load(%{assigns: %{root_id: nil}} = socket, _params),
    do: assign(socket, outputs: [], contexts: [])

  defp load(socket, params) do
    root = socket.assigns.root_id

    with {:ok, outputs} <- ReturnViews.invoke(@human, %{"action" => "outputs", "root_id" => root}),
         {:ok, contexts} <-
           ReturnViews.invoke(@human, %{"action" => "contexts", "root_id" => root}) do
      socket = assign(socket, outputs: outputs["outputs"], contexts: contexts)

      socket |> load_document(params["file"]) |> load_receipt(params["receipt"], contexts)
    else
      {:error, reason} -> assign(socket, outputs: [], contexts: [], error: inspect(reason))
    end
  end

  defp load_document(socket, nil), do: socket

  defp load_document(socket, path) do
    case ReturnViews.invoke(@human, %{
           "action" => "detail",
           "root_id" => socket.assigns.root_id,
           "path" => path
         }) do
      {:ok, doc} -> assign(socket, document: doc, feedback_id: Ecto.UUID.generate())
      {:error, reason} -> assign(socket, error: inspect(reason))
    end
  end

  defp load_receipt(socket, id, contexts) do
    if Enum.any?(contexts, &(&1["receipt_id"] == id)), do: read_receipt(socket, id), else: socket
  end

  defp read_receipt(socket, id) do
    case ReturnViews.invoke(@human, %{"action" => "context", "receipt_id" => id}) do
      {:ok, receipt} -> assign(socket, receipt: receipt)
      {:error, reason} -> assign(socket, error: inspect(reason))
    end
  end

  @impl true
  def handle_event("feedback", params, %{assigns: %{document: doc}} = socket) when is_map(doc) do
    args =
      Map.merge(params, %{
        "action" => "feedback",
        "root_id" => socket.assigns.root_id,
        "path" => doc["path"],
        "expected_revision" => doc["revision"],
        "request_id" => socket.assigns.feedback_id
      })

    case ReturnViews.feedback_form(@human, args) do
      {:ok, _record} ->
        {:noreply,
         assign(socket,
           error: "Comment recorded for this revision. No edits or approval applied."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: inspect(reason))}
    end
  end

  def handle_event("feedback", _params, socket),
    do: {:noreply, assign(socket, error: "Open a current document first.")}

  @impl true
  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl true
  def render(assigns) do
    ~H"""
    <.page active={:console} fleet_today={@fleet_today} attention_signals={@attention_signals}>
      <section class="mx-auto max-w-4xl space-y-4">
        <div class="flex items-center gap-3"><h1 class="text-xl font-semibold">Subject outputs</h1><.link navigate="/console" class="link text-sm">Control room</.link></div>
        <p class="text-sm text-base-content/70">Current files include human edits. Reports and historical tool payloads are separate evidence. Opening a file never resumes an agent.</p>
        <nav aria-label="Subject roots" class="flex flex-wrap gap-2"><.link :for={root <- @roots} navigate={root_path(root["root_id"])} class="btn btn-sm btn-ghost">{root["subject"]}</.link></nav>
        <p :if={@roots == []} class="text-base-content/70">No subject roots configured.</p>
        <p :if={@error} role="status" class="text-sm text-warning">{@error}</p>
        <ul id="subject-output-list" class="space-y-2">
          <li :for={output <- @outputs} class="rounded-box border border-base-300 p-3">
            <.link navigate={root_path(@root_id) <> "?file=" <> URI.encode_www_form(output["path"])} class="link font-mono">{output["path"]}</.link>
            <p class="break-all text-xs text-base-content/60">{output["revision"] || output["reason"]}</p>
            <span class="badge badge-ghost badge-sm">Document, acceptance unknown</span>
          </li>
        </ul>
        <article :if={@document} id="subject-document" class="card border border-base-300 bg-base-100">
          <div class="card-body">
            <h2 class="card-title">{@document["path"]}</h2>
            <p class="break-all text-xs">Revision {@document["revision"]}</p>
            <details id="document-content" open><summary class="cursor-pointer font-semibold">Current content</summary><pre class="max-h-96 overflow-auto whitespace-pre-wrap text-sm">{@document["content"]}</pre></details>
            <details id="document-producers"><summary class="cursor-pointer">Recorded production</summary><pre class="overflow-auto whitespace-pre-wrap text-xs">{Jason.encode!(@document["production_receipts"], pretty: true)}</pre></details>
            <details id="recorded-feedback"><summary class="cursor-pointer">Recorded comments</summary><ul><li :for={comment <- @document["feedback"]} class="py-2 text-sm"><p>{comment["comment"]}</p><span class="text-xs text-base-content/60">Lines {comment["start_line"]} to {comment["end_line"]} · {if comment["matches_current_revision"], do: "current revision", else: "historical revision"}</span></li></ul></details>
            <form id="document-feedback" phx-submit="feedback" class="space-y-2">
              <p class="text-sm">Comment on this revision and line range. Changes require reread and reanchor.</p>
              <div class="flex gap-2"><label>First line<input name="start_line" type="number" min="1" value="1" class="input input-sm w-24" /></label><label>Last line<input name="end_line" type="number" min="1" value="1" class="input input-sm w-24" /></label></div>
              <label class="block">Comment<textarea name="comment" required maxlength="2000" class="textarea w-full" /></label>
              <button type="submit" class="btn btn-primary btn-sm">Record comment</button>
            </form>
          </div>
        </article>
        <details id="subject-contexts"><summary class="cursor-pointer font-semibold">Historical tool context ({length(@contexts)})</summary>
          <ul><li :for={row <- @contexts}><.link navigate={root_path(@root_id) <> "?receipt=" <> URI.encode_www_form(row["receipt_id"])} class="link text-sm">{row["path"]} · {row["state"]} · {row["payload_state"]}</.link></li></ul>
        </details>
        <article :if={@receipt} id="context-receipt" class="card border border-base-300 bg-base-100"><div class="card-body">
          <h2 class="card-title">Historical tool payload</h2><p class="text-sm">{@receipt["state"]}; model receipt and use unknown. Hidden native context unavailable.</p>
          <p :if={@receipt["payload_state"] == "expired"}>Payload expired. Current files are not substituted.</p>
          <details :if={@receipt["exact_tool_text"]} id="receipt-content"><summary class="cursor-pointer">Exact retained text</summary><pre class="max-h-96 overflow-auto whitespace-pre-wrap text-sm">{@receipt["exact_tool_text"]}</pre></details>
        </div></article>
      </section>
    </.page>
    """
  end

  defp root_path(nil), do: "/subjects"
  defp root_path(root), do: "/subjects/" <> URI.encode_www_form(root)
end
