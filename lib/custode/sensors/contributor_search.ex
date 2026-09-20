defmodule Custode.Sensors.ContributorSearch do
  @moduledoc """
  The first sensor: mechanical detection of contributor-authored issues and
  PRs, no claude involved. Runs the exact gh searches as argv lists (no
  shell-string composition, no flag-swallowing) and filters bot authors.

  `baseline: :silent`: the first run remembers everything pre-existing
  without a note -- old contributor items are not news the way a failing
  check or a fresh earthquake is.

  A `gh` that fails is a fetch error, never an empty result (#479). The two
  used to be the same thing here, and that cost twice: the run never counted
  toward `Custode.Sensor.Health`, so a sensor whose `gh` was logged out could
  not raise `sensor_failing` (#444, #468), and the empty result replaced the
  seen-set, so the first run after recovery noted every open item as new.
  """

  use Custode.Sensor, baseline: :silent

  @bots ~w(dependabot github-actions release-please renovate copilot)

  @impl Custode.Sensor
  def fetch(args) do
    owners = Map.get(args, "owners", ["joshrotenberg", "genagent"])
    exclude = Map.get(args, "exclude_authors", ["joshrotenberg"])
    fetch_items(owners, exclude)
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

  @doc """
  Fetch current open contributor-authored items across owners, bots excluded.

  Either search failing fails the whole fetch (#479). Issues without PRs is
  not a smaller answer, it is a wrong one: `Custode.Sensor` replaces the
  seen-set with whatever comes back, so the missing half would be forgotten
  and then noted again as new.
  """
  @spec fetch_items([String.t()], [String.t()]) :: {:ok, [map()]} | {:error, String.t()}
  def fetch_items(owners, exclude_authors) do
    with {:ok, issues} <- search("issues", owners, exclude_authors),
         {:ok, prs} <- search("prs", owners, exclude_authors) do
      {:ok, Enum.reject(issues ++ prs, &bot?(&1.author))}
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
        items =
          for item <- Jason.decode!(json) do
            %{
              key: item["repository"]["nameWithOwner"] <> "#" <> to_string(item["number"]),
              author: get_in(item, ["author", "login"]) || "?",
              title: item["title"] || ""
            }
          end

        {:ok, items}

      {:error, reason} ->
        {:error, reason}
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
  @moduledoc """
  The real gh invocation: argv list in, stdout out. Swapped in tests.

  A failure comes back as one short line (#479). It lands in the feed and on
  the `sensor_failing` signal, and what `gh` prints when it fails can run to a
  screen of usage text.
  """

  @behaviour Custode.Sensors.GhRunnerBehaviour

  @reason_limit 160

  @impl true
  def run(argv) do
    case System.cmd("gh", argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, failure(code, out)}
    end
  rescue
    # `System.cmd/3` raises when there is no `gh` to run (`:enoent`), and a
    # sensor that raises never reaches `Custode.Sensor.Health`.
    error in ErlangError -> {:error, clip("gh could not be run: #{inspect(error.original)}")}
  end

  @doc """
  A non-zero `gh` exit as one line: the exit code and the first line it
  printed, at most #{@reason_limit} characters.

      iex> Custode.Sensors.GhRunner.failure(4, "To get started with GitHub CLI, please run:  gh auth login\\nAlternatively, populate the GH_TOKEN environment variable.\\n")
      "gh exited 4: To get started with GitHub CLI, please run:  gh auth login"

      iex> Custode.Sensors.GhRunner.failure(1, "")
      "gh exited 1"
  """
  @spec failure(non_neg_integer(), String.t()) :: String.t()
  def failure(code, out) do
    first_line = out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))

    if first_line, do: clip("gh exited #{code}: #{first_line}"), else: "gh exited #{code}"
  end

  defp clip(text), do: String.slice(text, 0, @reason_limit)
end
