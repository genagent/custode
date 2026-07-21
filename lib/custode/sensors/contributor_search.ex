defmodule Custode.Sensors.ContributorSearch do
  @moduledoc """
  The first sensor: mechanical detection of contributor-authored issues and
  PRs, no claude involved. Runs the exact gh searches as argv lists (no
  shell-string composition, no flag-swallowing), filters bot authors, diffs
  against its own memory (`sensor:<id>` / `"seen"`), and -- only when
  genuinely new items exist -- drops one inbox note for the watch routine,
  which the event kickoff turns into a beat.

  First run baselines silently (everything pre-existing is remembered, no
  note). The seen-set is replaced wholesale each run, so closed items age
  out on their own.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  @bots ~w(dependabot github-actions release-please renovate copilot)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    sensor_id = Map.fetch!(args, "sensor_id")
    notify = Map.fetch!(args, "notify")
    owners = Map.get(args, "owners", ["joshrotenberg", "genagent"])
    exclude = Map.get(args, "exclude_authors", ["joshrotenberg"])

    current = fetch_items(owners, exclude)
    current_keys = MapSet.new(current, & &1.key)

    memory_key = "sensor:" <> sensor_id

    case Custode.Memory.recall(memory_key, "seen") do
      :error ->
        # first run: baseline silently
        remember!(memory_key, current_keys)

        Custode.Feed.record(%{
          event: "sensor",
          agent: notify,
          summary: "#{sensor_id}: baseline recorded (#{MapSet.size(current_keys)} known items)"
        })

        :ok

      {:ok, seen_json} ->
        seen = seen_json |> Jason.decode!() |> MapSet.new()
        new_items = Enum.filter(current, &(not MapSet.member?(seen, &1.key)))
        remember!(memory_key, current_keys)
        report(sensor_id, notify, new_items)
    end
  end

  defp report(sensor_id, _notify, []) do
    Custode.Feed.record(%{event: "sensor", agent: "?", summary: "#{sensor_id}: nothing new"})
    :ok
  end

  defp report(sensor_id, notify, new_items) do
    lines =
      for item <- new_items do
        "- #{item.key} by #{item.author}: #{item.title}"
      end

    {:ok, _path} =
      Custode.Inbox.drop(
        notify,
        "sensor-#{sensor_id}-#{System.unique_integer([:positive])}.md",
        """
        Sensor #{sensor_id}: #{length(new_items)} new contributor item(s) detected.

        #{Enum.join(lines, "\n")}

        Verify, journal each, and raise your alert per standing orders.
        """
      )

    Custode.Feed.record(%{
      event: "sensor",
      agent: notify,
      summary: "#{sensor_id}: #{length(new_items)} new item(s), note dropped"
    })

    :ok
  end

  defp remember!(memory_key, current_keys) do
    :ok = Custode.Memory.remember(memory_key, "seen", Jason.encode!(MapSet.to_list(current_keys)))
  end

  @doc "Fetch current open contributor-authored items across owners, bots excluded."
  def fetch_items(owners, exclude_authors) do
    for kind <- ["issues", "prs"],
        item <- search(kind, owners, exclude_authors),
        not bot?(item.author) do
      item
    end
  end

  defp search(kind, owners, exclude_authors) do
    owner_flags = Enum.flat_map(owners, &["--owner", &1])
    query_terms = Enum.map(exclude_authors, &("-author:" <> &1))

    argv =
      ["search", kind] ++
        owner_flags ++
        ["--state", "open", "--limit", "100", "--json", "repository,number,author,title", "--"] ++
        query_terms

    case gh_runner().run(argv) do
      {:ok, json} ->
        for item <- Jason.decode!(json) do
          %{
            key: item["repository"]["nameWithOwner"] <> "#" <> to_string(item["number"]),
            author: get_in(item, ["author", "login"]) || "?",
            title: item["title"] || ""
          }
        end

      {:error, _reason} ->
        []
    end
  end

  defp bot?(author) do
    String.ends_with?(author, "[bot]") or
      Enum.any?(@bots, &String.starts_with?(author, &1))
  end

  defp gh_runner do
    Application.get_env(:custode, :gh_runner, Custode.Sensors.GhRunner)
  end
end

defmodule Custode.Sensors.GhRunner do
  @moduledoc "The real gh invocation: argv list in, stdout out. Swapped in tests."

  def run(argv) do
    case System.cmd("gh", argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end
end
