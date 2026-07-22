defmodule Custode.Test.FakeGhRunner do
  @moduledoc """
  Test stand-in for `Custode.Sensors.GhRunner`: returns canned JSON per
  search kind, set via `Application.put_env(:custode, :fake_gh_results, %{"issues" => [...], "prs" => [...]})`
  where each value is a list of raw gh item maps.
  """

  @behaviour Custode.Sensors.GhRunnerBehaviour

  @impl true
  def run(argv) do
    kind = Enum.at(argv, 1)
    results = Application.get_env(:custode, :fake_gh_results, %{})
    {:ok, Jason.encode!(Map.get(results, kind, []))}
  end
end
