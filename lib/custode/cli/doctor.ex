defmodule Custode.CLI.Doctor do
  @moduledoc """
  `mix custode doctor` -- the install preflight (#161): would a fleet boot
  and run on THIS machine, checked before anything paid or persistent
  happens?

  Unlike every other `mix custode` command, doctor does NOT go through the
  MCP client: its whole point is running before (or without) a server. Each
  check is a `{label, {:ok, info} | {:error, reason}}`; the process exits
  non-zero when any fails, so an install script can gate on it.

  What it checks, in dependency order:

    * the claude CLI is present, a usable version, and authenticated
      (claude_wrapper's own probes -- no paid calls)
    * the gh CLI is present and authenticated (repo panels, worker grants)
    * the configured `:timezone` resolves (tzdata reachable -- schedules and
      spend days both depend on it, #148/#164)
    * `Custode.Home.root/0` is writable (db, workspaces, tokens all land
      there)
    * the roster parses: a broken `routines.toml` should fail HERE, not at
      boot
  """

  use Cheer.Command

  alias Custode.Config.Loader
  alias Custode.Home
  alias ObanClaude.CLI.Doctor, as: SharedDoctor

  command "doctor" do
    about("Install preflight: claude, gh, timezone, home dir, and roster checks.")

    long_about("""
    Runs the fleet's environment checks without starting (or contacting) a
    server, and exits non-zero if any fails -- so a fresh-machine install
    can gate on `mix custode doctor` before the first boot. Makes no paid
    claude calls.
    """)

    option(:json, type: :boolean, help: "Print the report as JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {:ok, _} = Application.ensure_all_started(:claude_wrapper)
    {:ok, _} = Application.ensure_all_started(:tzdata)

    checks = checks()
    {text, ok?} = SharedDoctor.report(checks)

    cond do
      args[:json] == true -> Mix.shell().info(json(checks, ok?))
      ok? -> Mix.shell().info(text)
      true -> Mix.shell().error(text)
    end

    if ok?, do: :ok, else: {:error, :run_failed}
  end

  @doc false
  # The check list, each independent so one failure never hides another.
  def checks do
    [
      {"claude binary + version", claude_probe(&ClaudeWrapper.version/0)},
      {"claude authentication", claude_probe(&ClaudeWrapper.auth_status/0)},
      {"gh binary + auth", gh_check()},
      {"timezone #{configured_tz()}", tz_check()},
      {"home #{Home.root()} writable", home_check()},
      {"roster", roster_check()}
    ]
  end

  # A missing binary is doctor's bread-and-butter failure, and the wrapper's
  # probes run in a linked task -- an :enoent there would kill the caller,
  # not return an error. Guard the PATH lookup before ever invoking them.
  defp claude_probe(fun) do
    if System.find_executable("claude") do
      fun.()
    else
      {:error, "claude not on PATH"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp gh_check do
    case System.find_executable("gh") do
      nil ->
        {:error, "gh not on PATH"}

      _path ->
        case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
          {_out, 0} -> {:ok, "authenticated"}
          {out, _nonzero} -> {:error, String.slice(out, 0, 120)}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp configured_tz, do: Application.get_env(:custode, :timezone, "Etc/UTC")

  defp tz_check do
    {:ok, DateTime.now!(configured_tz()) |> DateTime.to_iso8601()}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp home_check do
    probe = Path.join(Home.root(), ".doctor-probe-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(Home.root()),
         :ok <- File.write(probe, "ok"),
         :ok <- File.rm(probe) do
      {:ok, "writable"}
    else
      {:error, posix} -> {:error, posix}
    end
  end

  defp roster_check do
    case Loader.load() do
      {:ok, path, routines, sensors} ->
        {:ok, "#{path}: #{length(routines)} routine(s), #{length(sensors)} sensor(s)"}

      :no_file ->
        {:ok, "no routines.toml; the config.exs roster serves"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp json(checks, ok?) do
    Jason.encode!(%{
      ok: ok?,
      checks:
        Enum.map(checks, fn
          {label, {:ok, info}} -> %{check: label, ok: true, info: inspect(info)}
          {label, {:error, reason}} -> %{check: label, ok: false, reason: inspect(reason)}
        end)
    })
  end
end
