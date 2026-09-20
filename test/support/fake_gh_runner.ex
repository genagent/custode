defmodule Custode.Test.FakeGhRunner do
  @moduledoc """
  Test stand-in for `Custode.Sensors.GhRunner`: returns canned JSON per
  search kind, set via `Application.put_env(:custode, :fake_gh_results, %{"issues" => [...], "prs" => [...]})`
  where each value is a list of raw gh item maps, or `{:error, reason}` to make
  that search fail the way a logged-out or rate-limited `gh` does (#479).
  """

  @behaviour Custode.Sensors.GhRunnerBehaviour

  @impl true
  def run(argv) do
    kind = Enum.at(argv, 1)
    results = Application.get_env(:custode, :fake_gh_results, %{})

    case Map.get(results, kind, []) do
      {:error, reason} -> {:error, reason}
      items -> {:ok, Jason.encode!(items)}
    end
  end
end
