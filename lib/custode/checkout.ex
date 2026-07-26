defmodule Custode.Checkout do
  @moduledoc """
  Whether the code on this machine is the code that was merged (#311).

  The failure this exists for was not a database problem and not a code
  problem. A checkout three commits behind `origin/main` was restarted, and
  the merged fix and the running code had simply never met. Every other
  preflight check passed, correctly, because the environment WAS clean.

  ## No fetch

  Position: **this performs no network fetch.** `doctor` already shells out
  for `gh auth status`, so the cost would be comparable, but a fetch MUTATES
  the repository, and a preflight that changes the thing it is inspecting is
  a different tool.

  The consequence is that the comparison is only as fresh as the last fetch,
  and a stale comparison that reads as reassurance is worse than none. So the
  age of the last fetch is reported alongside the answer rather than left for
  the reader to assume.

  ## Not every install is a checkout

  design/003's binary target ships a release with no git repository at all.
  That is not a degraded state, so it answers `:not_a_checkout` rather than
  failing.
  """

  @typedoc "How long ago the remote-tracking refs last learned anything."
  @type fetched :: String.t() | :never

  @type status ::
          {:behind, non_neg_integer(), fetched()}
          | {:current, fetched()}
          | :no_upstream
          | :not_a_checkout

  @doc """
  How this checkout stands against its upstream.

    * `{:behind, count, fetched}` -- `count` commits behind, last fetch `fetched` ago
    * `{:current, fetched}` -- up to date as of that fetch
    * `:no_upstream` -- a branch tracking nothing
    * `:not_a_checkout` -- no git repository (a release, typically)
  """
  @spec status(String.t()) :: status()
  def status(dir \\ File.cwd!()) do
    if git(dir, ["rev-parse", "--is-inside-work-tree"]) == {:ok, "true"} do
      upstream_status(dir)
    else
      :not_a_checkout
    end
  end

  @doc """
  A one-line rendering of `status/1` for the preflight report.

      iex> Custode.Checkout.describe(:not_a_checkout)
      "not a git checkout"
  """
  @spec describe(status()) :: String.t()
  def describe({:behind, count, fetched}),
    do: "#{count} commit(s) behind upstream #{as_of(fetched)} -- git pull first"

  # "up to date (never fetched)" would be a contradiction dressed as
  # reassurance, which is the exact failure mode this check exists to avoid.
  def describe({:current, :never}),
    do: "level with upstream, but this clone has never fetched -- git pull to be sure"

  def describe({:current, fetched}), do: "up to date #{as_of(fetched)}"
  def describe(:no_upstream), do: "branch tracks no upstream; nothing to compare"
  def describe(:not_a_checkout), do: "not a git checkout"

  defp as_of(:never), do: "(this clone has never fetched)"
  defp as_of(fetched), do: "as of your last fetch #{fetched}"

  defp upstream_status(dir) do
    case git(dir, ["rev-list", "--count", "HEAD..@{upstream}"]) do
      {:ok, count} ->
        case Integer.parse(count) do
          {0, _rest} -> {:current, fetched_ago(dir)}
          {behind, _rest} -> {:behind, behind, fetched_ago(dir)}
          :error -> :no_upstream
        end

      {:error, _reason} ->
        :no_upstream
    end
  end

  # FETCH_HEAD is rewritten by every fetch, so its mtime is when the
  # remote-tracking refs last learned anything. Resolved through
  # --git-common-dir rather than assuming `.git/`: in a linked worktree `.git`
  # is a FILE pointing elsewhere, and remote refs live in the common dir
  # shared with the main checkout.
  defp fetched_ago(dir) do
    with {:ok, git_dir} <- git(dir, ["rev-parse", "--git-common-dir"]),
         {:ok, %File.Stat{mtime: mtime}} <-
           File.stat(Path.expand(Path.join(git_dir, "FETCH_HEAD"), dir), time: :posix) do
      ago(System.os_time(:second) - mtime)
    else
      _never -> :never
    end
  end

  defp ago(seconds) when seconds < 60, do: "just now"
  defp ago(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp ago(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h ago"
  defp ago(seconds), do: "#{div(seconds, 86_400)}d ago"

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _nonzero} -> {:error, String.trim(out)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
