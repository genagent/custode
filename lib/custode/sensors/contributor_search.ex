defmodule Custode.Sensors.ContributorSearch do
  @moduledoc """
  The first sensor: mechanical detection of contributor-authored issues and
  PRs, no claude involved. Runs the exact gh searches as argv lists (no
  shell-string composition, no flag-swallowing) and filters bot authors.

  `baseline: :silent`: the first run remembers everything pre-existing
  without a note -- old contributor items are not news the way a failing
  check or a fresh earthquake is.
  """

  use Custode.Sensor, baseline: :silent

  @bots ~w(dependabot github-actions release-please renovate copilot)

  @impl Custode.Sensor
  def fetch(args) do
    owners = Map.get(args, "owners", ["joshrotenberg", "genagent"])
    exclude = Map.get(args, "exclude_authors", ["joshrotenberg"])
    {:ok, fetch_items(owners, exclude)}
  end

  @impl Custode.Sensor
  def key(item), do: item.key

  @impl Custode.Sensor
  def note(new_items, _args) do
    lines =
      for item <- new_items do
        "- #{item.key} by #{item.author}: #{item.title}"
      end

    """
    Sensor: #{length(new_items)} new contributor item(s) detected.

    #{Enum.join(lines, "\n")}

    Verify, journal each, and raise your alert per standing orders.
    """
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

defmodule Custode.Sensors.GhRunnerBehaviour do
  @moduledoc "The `:gh_runner` contract (#92): argv list in, stdout out."

  @callback run(argv :: [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
end

defmodule Custode.Sensors.GhRunner do
  @moduledoc "The real gh invocation: argv list in, stdout out. Swapped in tests."

  @behaviour Custode.Sensors.GhRunnerBehaviour

  @impl true
  def run(argv) do
    case System.cmd("gh", argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end
end
