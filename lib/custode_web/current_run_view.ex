defmodule CustodeWeb.CurrentRunView do
  @moduledoc "Compact rendering of the shared current-run projection."
  use Phoenix.Component

  attr(:facts, :any, required: true)

  def strip(assigns) do
    ~H"""
    <details :if={@facts} id="current-run-facts" class="mt-2 rounded-box border border-base-300 bg-base-100 px-3 py-2 text-xs">
      <summary class="cursor-pointer font-semibold">
        Input: {@facts.input.queued} queued · {@facts.input.admitting} admitting · {@facts.input.executing} executing
        <span :if={@facts.input.waiting_for_input > 0}> · {@facts.input.waiting_for_input} awaiting an answer</span>
        <span :if={@facts.input.waiting_for_approval > 0}> · {@facts.input.waiting_for_approval} awaiting approval</span>
        · {length(@facts.helpers.entries)} retained helpers
      </summary>
      <p class="mt-2 text-base-content/60">Independently observed. Removing a helper or pausing does not confirm its process has stopped.</p>
      <p class="mt-1 text-base-content/60">Plan document: no identified revision available.</p>
      <div :if={@facts.execution.facts.active} class="mt-2 break-all font-mono">
        Actual turn: {@facts.execution.facts.active.provider} · {@facts.execution.facts.active.model || "model unknown"}
        · job {@facts.execution.facts.active.id} · turn {@facts.execution.facts.active.turn_id}
      </div>
      <div :for={receipt <- @facts.input.receipts} class="mt-1 break-all font-mono">
        {receipt.message_id}: {receipt.delivery || "delivery unknown"} / {receipt.status}
      </div>
      <p :if={@facts.input.has_more_receipts} class="mt-1 text-base-content/60">Showing the oldest 20 receipts; counts cover all pending direct input.</p>
      <details :for={helper <- @facts.helpers.entries} class="mt-2 rounded-box bg-base-200 px-2 py-1">
        <summary class="cursor-pointer break-all">{helper.agent_id} · {helper.registry_state} · settlement unknown</summary>
        <.link navigate={helper.owner_link} class="link">Return to owner</.link>
        <p :for={report <- helper.reports} class="mt-1 break-words">Agent report: {report.summary}</p>
        <div :for={receipt <- helper.receipts} class="mt-1 break-all font-mono">
          {receipt.message_id}: {receipt.status}; read exact result with await_agent(message_id).
          <details :if={receipt.result_preview} class="mt-1"><summary class="cursor-pointer">Result preview (up to 2,000 characters)</summary><p class="whitespace-pre-wrap break-words">{receipt.result_preview}</p></details>
        </div>
      </details>
      <p :if={@facts.helpers.has_more} class="mt-1 text-base-content/60">Showing the newest 20 retained helpers.</p>
    </details>
    """
  end
end
