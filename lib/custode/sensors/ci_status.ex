defmodule Custode.Sensors.CiStatus do
  @moduledoc """
  Mechanical CI watch for a repo-tied routine (issue #32): polls the repo's
  open PRs through the same `Custode.GitHub` fetcher the dashboard panels
  use and wakes the routine when a PR *transitions* to failing -- instead
  of the red PR sitting until the next @daily sweep. A persistently red PR
  notes once, a recovered PR ages out, a re-break notes again.
  """

  use Custode.Sensor

  @failing ~w(FAILURE ERROR)

  @impl Custode.Sensor
  def fetch(args) do
    repo = Map.fetch!(args, "repo")

    with {:ok, overview} <- Custode.GitHub.fetcher().fetch(repo) do
      {:ok, Enum.filter(overview.open_prs.items, &(&1.checks in @failing))}
    end
  end

  @impl Custode.Sensor
  def key(pr), do: to_string(pr.number)

  @impl Custode.Sensor
  def note(new_failing, args) do
    repo = Map.fetch!(args, "repo")

    lines =
      for pr <- new_failing do
        "- PR ##{pr.number} (#{pr.title}): checks #{pr.checks} -- #{pr.url}"
      end

    """
    Sensor: CI is failing on #{length(new_failing)} open PR(s) in #{repo}.

    #{Enum.join(lines, "\n")}

    Per your standing orders, a red check on your own PR outranks new
    backlog work: read the failing job's log, propose the fix as this
    sweep's gated action, and push to the SAME branch (no new PR).
    """
  end
end
