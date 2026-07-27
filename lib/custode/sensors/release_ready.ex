defmodule Custode.Sensors.ReleaseReady do
  @moduledoc """
  Notices when a watched repository is due for a release (#336).

  ## Why a sensor and not a role

  `Custode.Sensor`'s contract is "cheap sensor, expensive brain", and release
  readiness splits along exactly that line. Counting unreleased merges and
  measuring time since the last tag is mechanical and costs nothing. Deciding
  whether THESE changes deserve a release is judgment, and the repository
  already has an agent whose job that is.

  So this wakes the existing worker with the evidence rather than becoming a
  second agent with an opinion. A dedicated `releaser` is the richer shape the
  design mocks show, and it needs crews, which are blocked on #300.

  ## What it costs

  Nothing extra. `latestRelease` and the merged-PR window ride the GraphQL
  query `Custode.GitHub` was already making per repo, the same way the branch
  build did in #310.

  ## Due, and the shape of the heuristic

  Two thresholds, both tunable per sensor entry:

    * `min_merged` (default 8) -- enough unreleased work to be worth shipping
    * `min_days` (default 21) -- unreleased work that has been sitting

  A repo is due when there is unreleased work AND either threshold is met.
  The `and` matters: a single docs fix three weeks old is not a release, and
  saying it is would teach the operator to ignore this sensor by the second
  week.

  design/005 argues thresholds belong in thresholds precisely because they are
  cheap, legible and spend no tokens. The judgment left over -- whether this
  particular pile is worth a version number -- is the agent's, which is why
  the note ends with a question rather than an instruction.

  ## Keyed by release, so it says it once

  The item's key is the current release tag. While that tag is newest and the
  repo stays due, the agent is told once. When a release lands the tag
  changes, the seen-set ages out, and the next time the repo grows overdue it
  is news again.
  """

  use Custode.Sensor

  @min_merged 8
  @min_days 21

  @impl Custode.Sensor
  def fetch(args) do
    repo = Map.fetch!(args, "repo")

    with {:ok, overview} <- Custode.GitHub.fetcher().fetch(repo) do
      {:ok, due(overview[:release], args)}
    end
  end

  # No release data at all (an old cache, a repo the query could not shape)
  # is not evidence of being due.
  defp due(nil, _args), do: []

  defp due(release, args) do
    days = days_since(release.published_at)
    merged = release.merged_since

    if merged > 0 and (merged >= min_merged(args) or over_days?(days, args)) do
      [Map.merge(release, %{days_since: days})]
    else
      []
    end
  end

  defp over_days?(nil, _args), do: false
  defp over_days?(days, args), do: days >= min_days(args)

  defp min_merged(args), do: Map.get(args, "min_merged", @min_merged)
  defp min_days(args), do: Map.get(args, "min_days", @min_days)

  # A repo that has never released has no clock to measure, only a pile.
  defp days_since(nil), do: nil

  defp days_since(published_at) do
    DateTime.utc_now() |> DateTime.diff(published_at, :second) |> div(86_400)
  end

  @impl Custode.Sensor
  def key(item), do: "release:" <> (item.tag || "none")

  @impl Custode.Sensor
  def note([item | _rest], args) do
    repo = Map.fetch!(args, "repo")

    """
    Sensor: #{repo} looks due for a release.

    #{evidence(item)}

    This is an observation, not an instruction. You know what is in these
    changes and this sensor does not: a pile of dependency bumps is not a
    release and one fix a user is waiting on might be. If you judge it ready,
    propose the release as this sweep's gated action and say in the proposal
    what the version should be and why. If it is not ready, journal that with
    the reason -- a decision recorded once is worth more than the same
    question answered every sweep.
    """
  end

  defp evidence(item) do
    [
      released(item),
      merged(item),
      waited(item)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &("- " <> &1))
  end

  defp released(%{tag: nil}), do: "no release has ever been published"
  defp released(item), do: "last release #{item.tag}"

  # A saturated window is a floor, not a total. Saying "20+" rather than "20"
  # is the difference between a cap and a silent one.
  defp merged(%{merged_since: count, window_full?: true}),
    do: "#{count}+ merged pull requests since (the window is full, so there may be more)"

  defp merged(%{merged_since: count}), do: "#{count} merged pull requests since"

  defp waited(%{days_since: nil}), do: nil
  defp waited(%{days_since: days}), do: "#{days} days since that release"
end
