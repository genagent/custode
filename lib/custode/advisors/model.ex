defmodule Custode.Advisors.Model do
  @moduledoc """
  Retired model advisor (#781). Historical feed windows cannot identify the
  model used by each turn, and activity yield is not an acceptance baseline.
  Keep the worker module for old queued jobs; it produces no recommendations.
  Exact turn attribution and a meaningful quality baseline are prerequisites
  to any replacement. Existing execution configuration remains unchanged.
  """
  use Custode.Advisor
  @impl Custode.Advisor
  def observe, do: []
  @impl Custode.Advisor
  def suggest(_observations), do: []
  @impl Custode.Advisor
  def key(suggestion),
    do: "model:#{suggestion.routine_id}:#{suggestion.current}->#{suggestion.proposed}"
end
