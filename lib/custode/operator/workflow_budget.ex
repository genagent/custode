defmodule Custode.Operator.WorkflowBudget do
  @moduledoc "Shared operator wording for exact-pause workflow budget decisions."

  def resumed(receipt) do
    "Resume approved for this pause: budget #{budget(receipt.previous_budget_usd)} → " <>
      "#{budget(receipt.budget_usd)}. Check the run below for its current status."
  end

  def refused(:pause_required), do: "No pause reference was supplied. Refresh and try again."

  def refused(:stale_pause),
    do: "This run has a different budget pause now. Review its current status before resuming."

  def refused(:not_paused), do: "This run is no longer paused for its budget."
  def refused(:no_such_run), do: "This workflow run no longer exists."
  def refused(_reason), do: "The resume could not be approved. Refresh and try again."

  defp budget(nil), do: "unlimited"
  defp budget(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)
end
