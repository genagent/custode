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

  # The four-way split (design 003 D2), resolved by MODE:
  #   * CUSTODE_HOME set  -> every dir collapses under it (both modes)
  #   * source mode       -> every dir is the cwd (the dev loop, unchanged)
  #   * binary mode       -> the XDG base-dir split
  # The mode is the ARTIFACT (`config :custode, :mode`), set at build time --
  # a release stamps :binary; no runtime mix.exs sniffing. Callers already
  # bind to the specific dir, so only these functions learn about XDG.

  @doc "Operator-edited config: custode.toml, routines.toml, prompt overrides."
  def config_dir, do: dir(&xdg_config/0)

  @doc "What the fleet accumulates: db, workspace notebooks, feed mirror."
  def data_dir, do: dir(&xdg_data/0)

  @doc "Boot-scoped state: per-agent MCP configs, the operator token (#107)."
  def runtime_dir, do: dir(&xdg_runtime/0)

  @doc "What can burn: PLTs, response caches."
  def cache_dir, do: dir(&xdg_cache/0)

  @doc "The build-time mode: `:source` (mix, the default) or `:binary` (a release)."
  def mode, do: Application.get_env(:custode, :mode, :source)

  # CUSTODE_HOME collapses everything; else source -> cwd, binary -> XDG
  defp dir(xdg_fun) do
    cond do
      custode_home_set?() -> root()
      mode() == :binary -> xdg_fun.()
      true -> root()
    end
  end

  defp custode_home_set? do
    case System.get_env("CUSTODE_HOME") do
      home when is_binary(home) and home != "" -> true
      _unset -> false
    end
  end

  defp xdg_config, do: xdg("XDG_CONFIG_HOME", ".config")
  defp xdg_data, do: xdg("XDG_DATA_HOME", ".local/share")
  defp xdg_cache, do: xdg("XDG_CACHE_HOME", ".cache")

  # runtime state is boot-scoped (#107): XDG_RUNTIME_DIR is exactly that, and
  # losing it on restart is the point. Falls back to cache when unset.
  defp xdg_runtime do
    case System.get_env("XDG_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, "custode")
      _unset -> xdg_cache()
    end
  end

  defp xdg(env, default_rel) do
    base =
      case System.get_env(env) do
        dir when is_binary(dir) and dir != "" -> dir
        _unset -> Path.join(System.user_home!(), default_rel)
      end

    Path.join(base, "custode")
  end

  @doc "Resolve a path under a specific dir (absolute paths respected)."
  def resolve_in(dir, path) when is_function(dir, 0) do
    if Path.type(path) == :absolute, do: path, else: Path.join(dir.(), path)
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
