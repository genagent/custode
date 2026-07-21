defmodule Custode.Sensors.CiStatus do
  @moduledoc """
  Mechanical CI watch for a repo-tied routine (issue #32): polls the repo's
  open PRs through the same `Custode.GitHub` fetcher the dashboard panels
  use (the check rollup is already in that one GraphQL query), and when a PR
  *transitions* to failing, drops an inbox note whose event kickoff wakes
  the routine promptly -- instead of the red PR sitting until the next
  @daily sweep. No claude tokens are spent watching.

  Transition detection via `sensor:<id>` / `"failing"` memory: the set of
  failing PR numbers is replaced wholesale each run, so a persistently red
  PR notes once, a recovered PR ages out, and a PR that breaks again notes
  again. A fetch error skips the run (the next poll retries).
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  @failing ~w(FAILURE ERROR)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    sensor_id = Map.fetch!(args, "sensor_id")
    notify = Map.fetch!(args, "notify")
    repo = Map.fetch!(args, "repo")

    case Custode.GitHub.fetcher().fetch(repo) do
      {:ok, overview} ->
        check(sensor_id, notify, repo, failing_prs(overview))

      {:error, reason} ->
        Custode.Feed.record(%{
          event: "sensor",
          agent: notify,
          summary: "#{sensor_id}: fetch failed (#{inspect(reason)}), will retry next poll"
        })

        :ok
    end
  end

  defp failing_prs(overview) do
    Enum.filter(overview.open_prs.items, &(&1.checks in @failing))
  end

  defp check(sensor_id, notify, repo, failing) do
    memory_key = "sensor:" <> sensor_id
    failing_numbers = MapSet.new(failing, & &1.number)

    seen =
      case Custode.Memory.recall(memory_key, "failing") do
        {:ok, json} -> json |> Jason.decode!() |> MapSet.new()
        :error -> MapSet.new()
      end

    :ok =
      Custode.Memory.remember(
        memory_key,
        "failing",
        Jason.encode!(MapSet.to_list(failing_numbers))
      )

    case Enum.filter(failing, &(not MapSet.member?(seen, &1.number))) do
      [] ->
        Custode.Feed.record(%{
          event: "sensor",
          agent: notify,
          summary: "#{sensor_id}: #{MapSet.size(failing_numbers)} failing PR(s), nothing new"
        })

        :ok

      new_failing ->
        note!(sensor_id, notify, repo, new_failing)
    end
  end

  defp note!(sensor_id, notify, repo, new_failing) do
    lines =
      for pr <- new_failing do
        "- PR ##{pr.number} (#{pr.title}): checks #{pr.checks} -- #{pr.url}"
      end

    {:ok, _path} =
      Custode.Inbox.drop(
        notify,
        "sensor-#{sensor_id}-#{System.unique_integer([:positive])}.md",
        """
        Sensor #{sensor_id}: CI is failing on #{length(new_failing)} open PR(s) in #{repo}.

        #{Enum.join(lines, "\n")}

        Per your standing orders, a red check on your own PR outranks new
        backlog work: read the failing job's log, propose the fix as this
        sweep's gated action, and push to the SAME branch (no new PR).
        """
      )

    Custode.Feed.record(%{
      event: "sensor",
      agent: notify,
      summary: "#{sensor_id}: #{length(new_failing)} newly failing PR(s), note dropped"
    })

    :ok
  end
end
