defmodule Custode.Home do
  @moduledoc """
  The custode home directory (#41 / design 001 slice 5): where everything
  that is not source lives.

  Two modes, chosen by `$CUSTODE_HOME`:

    * **unset (source-repo mode)** -- the root is the current working
      directory, exactly the behavior the repo has always had: `custode.db`,
      `workspaces/`, `tmp/`, `feed.jsonl`, and `routines.toml` beside the
      code. Zero configuration, nothing changes for the dev loop.
    * **set (installed mode)** -- the root is `$CUSTODE_HOME` (say
      `~/.custode`), and every relative runtime path resolves under it. The
      checkout carries only source; a work-laptop install keeps its state in
      one directory that survives re-clones and can be backed up or deleted
      as a unit.

  One rule, applied at the choke points: RELATIVE runtime paths resolve
  against the root; ABSOLUTE paths are respected untouched (a roster that
  says `working_dir = "/Users/x/code/repo"` means it). `runtime.exs` roots
  the db, the MCP config dir, and the feed mirror; `Routine.normalize/1`
  roots workspaces; `Config.Loader` looks for the roster here.
  """

  @doc "The custode root: `$CUSTODE_HOME` (expanded) or the cwd."
  def root do
    case System.get_env("CUSTODE_HOME") do
      home when is_binary(home) and home != "" -> Path.expand(home)
      _unset -> File.cwd!()
    end
  end

  @doc """
  Resolve a runtime path: absolute stays as given, relative roots under
  `root/0`. The result is always absolute.
  """
  def resolve(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(root(), path)
    end
  end

  @doc "resolve/1 plus mkdir_p of the parent -- for paths about to be written."
  def resolve!(path) do
    resolved = resolve(path)
    File.mkdir_p!(Path.dirname(resolved))
    resolved
  end
end
