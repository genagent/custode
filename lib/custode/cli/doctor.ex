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
    * migration versions are unique, and how many are pending (#311) -- a
      duplicate version makes Ecto refuse the whole run, which otherwise
      surfaces as a supervision-tree crash on a fleet that has already stopped
    * the checkout is not behind its upstream, which is the state where a
      merged fix and the running code have never met
    * the organization's managed Claude Code settings, read from the files
      Claude Code reads (`Custode.ClaudeManagedSettings`): whether they drop
      custode's `--allowed-tools` (`allowManagedPermissionRulesOnly` without
      a managed allow rule for the custode server) or disable the
      `bypass_permissions` mode approved continuations use

  ## The restart protocol

      mix custode drain     # stop gracefully
      git pull              # the checkout check exists because this gets missed
      mix custode doctor    # this
      mix phx.server

  The last two checks are what make step 3 worth running after step 2 rather
  than instead of it.
  """

  use Cheer.Command

  alias Custode.ClaudeManagedSettings
  alias Custode.Config.Loader
  alias Custode.Home
  alias ObanClaude.CLI.Doctor, as: SharedDoctor

  command "doctor" do
    about(
      "Install preflight: claude, gh, timezone, home dir, roster and managed settings checks."
    )

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
      {"roster", roster_check()},
      {"migrations", migrations_check()},
      {"pending migrations", pending_check()},
      {"checkout", checkout_check()}
    ] ++ managed_settings_checks()
  end

  # Hard failure, because Ecto refuses the ENTIRE migration run on a duplicate
  # version rather than just the offending pair -- so this is never survivable
  # at boot, and it is detectable from filenames alone (#311).
  defp migrations_check do
    case Custode.Migrations.duplicates(Custode.Migrations.files()) do
      [] ->
        {:ok, "#{length(Custode.Migrations.files())} migration(s), versions unique"}

      dupes ->
        {:error,
         Enum.map_join(dupes, "; ", fn {version, files} ->
           "version #{version} claimed by #{Enum.join(files, " and ")}"
         end)}
    end
  end

  # Informational: a restart that is about to change the schema should say so
  # first. A fresh install has no database, which is an answer and not a
  # failure -- it is the normal case for design/003's binary target.
  defp pending_check do
    case Custode.Migrations.pending() do
      {:ok, 0} -> {:ok, "none; schema is current"}
      {:ok, count} -> {:ok, "#{count} will run on the next boot"}
      {:fresh, count} -> {:ok, "no database yet; all #{count} run on first boot"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Behind upstream is a hard failure: it is the state in which a merged fix
  # and the running code have never met, and every other check passes anyway
  # because the environment really is clean (#311).
  defp checkout_check do
    status = Custode.Checkout.status()
    description = Custode.Checkout.describe(status)

    case status do
      {:behind, _count, _fetched} -> {:error, description}
      _current_or_skipped -> {:ok, description}
    end
  end

  # Warnings, not failures, like pending migrations: a managed policy is an
  # answer about this machine, not a reason the fleet cannot boot. Codex and
  # non-MCP routines are unaffected, the operator cannot change the policy
  # locally, and a permanent non-zero exit would only block install scripts.
  # The shared report has no third level, so the info text says "warning:".
  defp managed_settings_checks do
    policy =
      :custode
      |> Application.get_env(:claude_managed_settings, [])
      |> ClaudeManagedSettings.read()
      |> ClaudeManagedSettings.policy()

    [
      {"claude managed permission rules",
       {:ok, ClaudeManagedSettings.describe_permission_rules(policy, custode_tools())}},
      {"claude bypass permissions mode", {:ok, ClaudeManagedSettings.describe_bypass(policy)}}
    ]
  rescue
    error ->
      [{"claude managed settings", {:ok, "warning: not read: " <> Exception.message(error)}}]
  end

  # Every tool any role's --allowed-tools names on the custode server.
  defp custode_tools do
    Custode.Roles.all()
    |> Map.keys()
    |> Enum.flat_map(&Custode.Routine.mcp_tools/1)
    |> Enum.uniq()
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
      {:ok, path, routines, sensors, profiles} ->
        {:ok,
         "#{path}: #{length(routines)} routine(s), #{length(sensors)} sensor(s), " <>
           "#{map_size(profiles)} profile(s)"}

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
