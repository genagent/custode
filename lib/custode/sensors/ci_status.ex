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

  @failing ~w(FAILURE ERROR)

  @impl Custode.Sensor
  def fetch(args) do
    repo = Map.fetch!(args, "repo")

    with {:ok, overview} <- Custode.GitHub.fetcher().fetch(repo) do
      failing_prs =
        overview.open_prs.items
        |> Enum.filter(&(&1.checks in @failing))
        |> Enum.map(&Map.put(&1, :kind, :pr))

      {:ok, branch_items(overview) ++ failing_prs}
    end
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
