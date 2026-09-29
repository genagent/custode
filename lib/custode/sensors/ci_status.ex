defmodule Custode.Sensors.CiStatus do
  @moduledoc """
  Mechanical CI watch for a repo-tied routine (issue #32): polls the repo
  through the same `Custode.GitHub` fetcher the dashboard panels use and wakes
  the routine when a build *transitions* to failing -- instead of the red
  sitting until the next @daily sweep. A persistently red build notes once, a
  recovered one ages out, a re-break notes again.

  Two kinds of build, since #310:

    * **open pull requests**, keyed by number. The agent's own work.
    * **the default branch**, keyed by name. Not necessarily the agent's work,
      and worse when it is broken: a red `main` blocks every merge and can
      make a restart fail outright.

  The branch rides the same seen-set diff rather than getting its own
  mechanism, so it inherits the transition semantics for free. It is keyed by
  NAME and not by commit: while `main` stays red the agent is told once, and
  a fresh red commit on an already-red branch is not news it can act on
  differently.

  `Custode.Attention`'s `:red_main` (#310) tells the OPERATOR about the same
  condition. This tells the agent. They are deliberately separate: the
  operator needs to know because it invalidates their next merge or restart,
  and the agent needs to know because it may be the one to fix it.
  """

  use Custode.Sensor

  alias Custode.Sensors.CiStatus.Infrastructure

  @failing ~w(FAILURE ERROR)
  @quiet_conclusions ~w(success neutral skipped)
  @default_infrastructure_failure_seconds 5

  @impl Custode.Sensor
  def fetch(args) do
    repo = Map.fetch!(args, "repo")
    observed_at = DateTime.utc_now()

    with {:ok, overview} <- Custode.GitHub.fetcher().fetch(repo) do
      max_seconds = infrastructure_failure_seconds(args)

      failing_prs =
        overview.open_prs.items
        |> Enum.filter(&(&1.checks in @failing))
        |> Enum.map(&Map.put(&1, :kind, :pr))

      {blocked, failing} =
        overview
        |> branch_items()
        |> Kernel.++(failing_prs)
        |> classify(repo, max_seconds)

      :ok = Infrastructure.replace(args, blocked, max_seconds, observed_at)

      {:ok, failing}
    end
  end

  defp classify(items, repo, max_seconds) do
    Enum.split_with(items, &infrastructure_blocked?(&1, repo, max_seconds))
  end

  defp infrastructure_blocked?(item, repo, max_seconds) do
    with true <- blockable_item?(item),
         {:ok, runs} <- check_runs(repo, item) do
      infrastructure_failure?(runs, max_seconds)
    else
      _not_blocked -> false
    end
  end

  defp blockable_item?(%{kind: :pr, number: number, head_sha: ref}),
    do: is_integer(number) and number > 0 and is_binary(ref) and ref != ""

  defp blockable_item?(%{kind: :branch, name: name, oid: ref}),
    do: is_binary(name) and name != "" and is_binary(ref) and ref != ""

  defp blockable_item?(_item), do: false

  defp check_runs(repo, %{kind: :pr, head_sha: ref}) when is_binary(ref) and ref != "",
    do: Custode.Repository.checks_for_ref(repo, ref)

  defp check_runs(repo, %{kind: :branch, oid: ref}) when is_binary(ref) and ref != "",
    do: Custode.Repository.checks_for_ref(repo, ref)

  defp check_runs(_repo, _item), do: {:error, :missing_ref}

  # A failed rollup is infrastructure-blocked only with complete positive
  # evidence: at least one ordinary failure, and no adverse run of any other
  # kind. Any missing or malformed timestamp leaves the item failing. That
  # conservative boundary keeps cancellations, timeouts, startup failures and
  # future GitHub conclusions from turning a real red build quiet.
  defp infrastructure_failure?(runs, max_seconds) when is_list(runs) do
    adverse =
      Enum.reject(runs, fn run ->
        normalized_status(run) == "completed" and
          normalized_conclusion(run) in @quiet_conclusions
      end)

    adverse != [] and
      Enum.any?(adverse, &(normalized_conclusion(&1) == "failure")) and
      Enum.all?(adverse, fn run ->
        normalized_status(run) == "completed" and
          normalized_conclusion(run) == "failure" and short_run?(run, max_seconds)
      end)
  end

  defp infrastructure_failure?(_runs, _max_seconds), do: false

  defp normalized_conclusion(run) when is_map(run) do
    case Map.get(run, :conclusion, Map.get(run, "conclusion")) do
      value when is_atom(value) -> value |> Atom.to_string() |> String.downcase()
      value when is_binary(value) -> String.downcase(value)
      _missing_or_unknown -> nil
    end
  end

  defp normalized_conclusion(_run), do: nil

  defp normalized_status(run) when is_map(run) do
    case Map.get(run, :status, Map.get(run, "status")) do
      value when is_atom(value) -> value |> Atom.to_string() |> String.downcase()
      value when is_binary(value) -> String.downcase(value)
      _missing_or_unknown -> nil
    end
  end

  defp normalized_status(_run), do: nil

  defp short_run?(run, max_seconds) do
    with {:ok, started_at} <- timestamp(run, :started_at),
         {:ok, completed_at} <- timestamp(run, :completed_at),
         elapsed when elapsed >= 0 <- DateTime.diff(completed_at, started_at, :microsecond) do
      elapsed <= max_seconds * 1_000_000
    else
      _invalid -> false
    end
  end

  defp timestamp(run, key) when is_map(run) do
    case Map.get(run, key, Map.get(run, Atom.to_string(key))) do
      %DateTime{} = at ->
        {:ok, at}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> {:ok, at}
          {:error, _reason} -> :error
        end

      _missing ->
        :error
    end
  end

  defp infrastructure_failure_seconds(args) do
    configured =
      Map.get(
        args,
        "infrastructure_failure_seconds",
        Application.get_env(
          :custode,
          :ci_infrastructure_failure_seconds,
          @default_infrastructure_failure_seconds
        )
      )

    if is_integer(configured) and configured >= 0,
      do: configured,
      else: @default_infrastructure_failure_seconds
  end

  # nil covers both an empty repository and a rollup that has not reported.
  # Absent is not the same as red, and only red is news.
  defp branch_items(%{default_branch: %{state: state} = branch}) when state in @failing do
    [%{kind: :branch, name: branch.name, headline: branch[:headline], oid: branch[:oid]}]
  end

  defp branch_items(_overview), do: []

  @impl Custode.Sensor
  def key(%{kind: :branch, name: name}), do: "branch:" <> name
  def key(pr), do: to_string(pr.number)

  @impl Custode.Sensor
  def note(new_failing, args) do
    repo = Map.fetch!(args, "repo")
    {branches, prs} = Enum.split_with(new_failing, &(&1.kind == :branch))

    [branch_note(branches, repo), pr_note(prs, repo)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp branch_note([], _repo), do: ""

  defp branch_note(branches, repo) do
    lines =
      for branch <- branches do
        "- #{branch.name} is red at #{branch.headline || branch.oid || "its tip"}"
      end

    """
    Sensor: the DEFAULT BRANCH is failing in #{repo}.

    #{Enum.join(lines, "\n")}

    This outranks everything else in your backlog. A red default branch
    blocks every merge and can make a restart fail outright, so it costs the
    whole fleet and not just you. Read the failing job's log first, then
    decide whether it is yours: a build broken by your own merge is yours to
    fix as this sweep's gated action. If it broke on someone else's commit,
    say so in your journal and raise it rather than guessing -- the operator
    is already being told, so a duplicate fix is worse than none.
    """
  end

  defp pr_note([], _repo), do: ""

  defp pr_note(prs, repo) do
    lines =
      for pr <- prs do
        "- PR ##{pr.number} (#{pr.title}): checks #{pr.checks} -- #{pr.url}"
      end

    """
    Sensor: CI is failing on #{length(prs)} open PR(s) in #{repo}.

    #{Enum.join(lines, "\n")}

    Per your standing orders, a red check on your own PR outranks new
    backlog work: read the failing job's log, propose the fix as this
    sweep's gated action, and push to the SAME branch (no new PR). If the PR
    is NOT yours, repo_disown_pr records that so its red check reaches the
    operator instead of sitting in your queue.
    """
  end
end
