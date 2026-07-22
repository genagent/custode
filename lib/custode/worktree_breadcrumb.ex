defmodule Custode.WorktreeBreadcrumb do
  @moduledoc """
  The worktree tripwire (#90): state breadcrumbs around every elevated turn.

  The one observed incident -- an elevated worktree reset to main's tip
  mid-turn -- had zero data. This module arms the trap: on run START (the
  telemetry oban_claude emits before the claude subprocess launches) and on
  run stop/exception, any turn carrying a `worktree` arg gets a
  `worktree_state` feed entry with the worktree's path, HEAD sha, and
  branch. A recurrence then shows exactly what the tree looked like when
  the turn began and what it looked like after -- a reset mid-turn becomes
  two entries that disagree, timestamped.

  Pure observability: no behavior changes, and the git introspection never
  raises (a breadcrumb must not cost a turn). Worktrees live where
  claude_wrapper materializes them: `<working_dir>/.claude/worktrees/<name>`.
  """

  require Logger

  @doc false
  def attach do
    :telemetry.attach_many(
      "custode-worktree-breadcrumb",
      [
        [:oban_claude, :run, :start],
        [:oban_claude, :run, :stop],
        [:oban_claude, :run, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  # Armored like every custode handler: raising here would detach the trap.
  def handle_event([:oban_claude, :run, phase], _measurements, meta, _config) do
    with %{"worktree" => name} when is_binary(name) <- meta.args,
         %{job: %{meta: %{"agent_id" => agent_id}}} <- meta do
      record(phase, agent_id, name, meta.args["working_dir"])
    end

    :ok
  rescue
    exception ->
      Logger.error(
        "Custode.WorktreeBreadcrumb handler error (kept attached): " <>
          Exception.message(exception)
      )

      :ok
  end

  defp record(phase, agent_id, name, working_dir) do
    path = worktree_path(name, working_dir)
    {sha, branch} = git_state(path)

    Custode.Feed.record(%{
      event: "worktree_state",
      agent: agent_id,
      phase: to_string(phase),
      worktree: path,
      sha: sha,
      branch: branch,
      summary: "worktree #{name} at #{to_string(phase)}: #{branch}@#{String.slice(sha, 0, 10)}"
    })
  end

  defp worktree_path(name, working_dir) do
    base = working_dir || File.cwd!()
    Path.join([Path.expand(base), ".claude", "worktrees", name])
  end

  # HEAD + branch, or honest placeholders: at run START the worktree may not
  # exist yet (claude_wrapper creates it inside the run) -- that is itself
  # signal, recorded as "absent".
  defp git_state(path) do
    if File.dir?(path) do
      {git(path, ["rev-parse", "HEAD"]), git(path, ["rev-parse", "--abbrev-ref", "HEAD"])}
    else
      {"absent", "absent"}
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _nonzero} -> "unreadable"
    end
  end
end
