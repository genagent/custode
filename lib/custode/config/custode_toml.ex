defmodule Custode.Config.CustodeToml do
  @moduledoc """
  The `custode.toml` loader (#267 / design 003 slice 2): the operator config
  beyond the roster. Where `routines.toml` carries the per-machine roster,
  `custode.toml` carries what an operator tunes -- fleet defaults, retention,
  and (later) the server and ambient surfaces.

  Loading follows the proven `Custode.Config.Loader` pattern: `runtime.exs`
  reads it (releases evaluate it without Mix), converts through explicit key
  whitelists to the exact shapes the exs config produces, applies via
  `config/2`, and fails the boot LOUDLY on an unknown key. Resolution is
  **per-section wins-outright**: a section the file carries overrides exs; a
  section it omits falls back -- "tune one budget without copying every
  policy" is the operator story.

  Absent file -> `:no_file`, and the exs config serves unchanged (source
  mode's dev loop is untouched). The loader is inert until a `custode.toml`
  exists, which today means a binary/install ships one.

  This module loads:

    * `[fleet]` -- timezone, model, max_budget_usd, daily_budget_usd
    * `[janitor]` -- feed_days, subagent_ttl_s
    * `[advisors]` -- advisor name -> cron string or `false` (#260)
    * `[server]` -- dashboard_port, mcp_port, `[server.dashboard_auth]` (#65)
    * `[ambient]` -- orders, the `Custode.Policy` opt-in selectors (#19)

  `[profiles]` and `[policies]` are still exs-only; they are design 003
  slice 3 (#268) and an unknown section until then.

  ## `[server]` is the live-server surface

  A wrong port or a half-written credential here is not a typo, it is a
  dashboard that does not come up or comes up unauthenticated, so this
  section validates harder than the scalars: ports must be integers in
  1..65535, and `[server.dashboard_auth]` must carry BOTH a username and a
  password (`Plug.BasicAuth` needs both, and half a credential is an open
  dashboard the operator believes is closed).

  `dashboard_port` lands as `CustodeWeb.Endpoint`'s `http: [port: ...]`
  rather than a key of its own. That entry is still `config :custode` config,
  so it rides the same keyword list, and `Config`'s deep merge replaces only
  the port -- the loopback `ip:` binding from the exs config survives, which
  is the point: this file tunes a port, it does not open an interface.

  ## `[ambient]` orders

  The design writes the opt-in as a list of single-key inline tables, which
  is TOML's spelling of `Custode.Policy`'s selector list:

      [ambient]
      orders = [{ repo = "genagent/custode" }, { role = "backlog_worker" }]

  becomes `ambient_orders: [repo: "genagent/custode", role: :backlog_worker]`.
  `repo` stays a string (it is compared to `routine.repo`); `role` and `tag`
  convert to atoms. `orders = "all"` is the `:all` selector, and `orders = []`
  is the default off.

  Each table must carry EXACTLY ONE key. Selectors are OR'd, so a two-key
  table reads as "repo AND role" and would silently mean "repo OR role" --
  that gap is worth a loud boot failure rather than a wider opt-in than the
  operator wrote.
  """

  # section table key -> the atom the exs config uses
  @fleet %{
    "timezone" => :timezone,
    "model" => :model,
    "max_budget_usd" => :max_budget_usd,
    "daily_budget_usd" => :daily_budget_usd
  }

  @janitor %{
    "feed_days" => :feed_days,
    "subagent_ttl_s" => :subagent_ttl_s
  }

  @ambient_selectors ~w(repo role tag)

  @doc """
  Find and parse `custode.toml` under the config dir. Returns `{:ok, path,
  custode_config}` (a keyword list ready to splat into `config :custode,
  ...`) or `:no_file`. Raises on a malformed file or an unknown key/section.
  """
  def load do
    path = Custode.Home.resolve_in(&Custode.Home.config_dir/0, "custode.toml")

    if File.exists?(path),
      do: {:ok, path, parse!(File.read!(path), path)},
      else: :no_file
  end

  @doc """
  Parse a `custode.toml` document into a keyword list for `config :custode`.
  Pure -- `runtime.exs` handles the file and the apply.
  """
  def parse!(toml, source \\ "custode.toml") do
    doc =
      case Toml.decode(toml) do
        {:ok, doc} -> doc
        {:error, reason} -> raise "#{source}: #{inspect(reason)}"
      end

    Enum.flat_map(doc, fn {section, table} -> convert_section(section, table, source) end)
  end

  @doc """
  The dashboard port a parsed config carries, or `default` when it omits
  `[server] dashboard_port`.

  `runtime.exs` needs the port a SECOND time, for #65's `check_origin`
  allowlist: that list names `http://localhost:<port>` so a local browser
  still connects its LiveView socket while tailscale proxies the public
  host, and a hardcoded 4646 there would go stale the moment this file
  moves the port.
  """
  def dashboard_port(custode_config, default) do
    get_in(custode_config, [CustodeWeb.Endpoint, :http, :port]) || default
  end

  defp convert_section("fleet", table, source), do: convert(table, @fleet, source, "fleet")

  defp convert_section("janitor", table, source),
    do: [{:janitor, convert(table, @janitor, source, "janitor")}]

  # [advisors] (#260): each key is an advisor name, each value a cron string
  # or `false` to disable. Names are validated at boot when the crontab
  # resolves them to modules, so the loader passes them through.
  defp convert_section("advisors", table, _source) do
    [{:advisors, Enum.map(table, fn {name, cron} -> {String.to_atom(name), cron} end)}]
  end

  # [server] (#65): the ports the fleet listens on plus the dashboard's
  # basic-auth credential. Each key converts to its own config shape, so
  # this section fans out rather than nesting under one atom.
  defp convert_section("server", table, source) do
    Enum.map(table, fn {key, value} -> server_key(key, value, source) end)
  end

  # [ambient] (#19): the Custode.Policy opt-in for repo-owned orders.
  defp convert_section("ambient", table, source) do
    Enum.map(table, fn
      {"orders", value} -> {:ambient_orders, ambient_orders(value, source)}
      {key, _value} -> raise "#{source}: unknown key #{inspect(key)} in [ambient]"
    end)
  end

  defp convert_section(section, _table, source) do
    raise "#{source}: unknown [#{section}] section in custode.toml"
  end

  # The endpoint's port, not a key of its own: deep merge replaces the port
  # and leaves the exs loopback `ip:` binding alone.
  defp server_key("dashboard_port", value, source),
    do: {CustodeWeb.Endpoint, [http: [port: port!(value, "dashboard_port", source)]]}

  defp server_key("mcp_port", value, source),
    do: {:mcp_port, port!(value, "mcp_port", source)}

  defp server_key("dashboard_auth", table, source) when is_map(table),
    do: {:dashboard_auth, dashboard_auth(table, source)}

  defp server_key(key, _value, source),
    do: raise("#{source}: unknown key #{inspect(key)} in [server]")

  defp port!(value, _key, _source) when is_integer(value) and value in 1..65_535, do: value

  defp port!(value, key, source) do
    raise "#{source}: #{key} in [server] must be a port 1..65535, got #{inspect(value)}"
  end

  # Both halves or neither: Plug.BasicAuth needs both, and half a credential
  # is an open dashboard the operator believes is closed.
  defp dashboard_auth(table, source) do
    case {table["username"], table["password"], Map.keys(table) -- ~w(username password)} do
      {username, password, []} when is_binary(username) and is_binary(password) ->
        [username: username, password: password]

      {_username, _password, [_ | _] = unknown} ->
        raise "#{source}: unknown key(s) #{inspect(unknown)} in [server.dashboard_auth]"

      _partial ->
        raise "#{source}: [server.dashboard_auth] needs both a username and a password"
    end
  end

  defp ambient_orders("all", _source), do: :all

  defp ambient_orders(selectors, source) when is_list(selectors),
    do: Enum.map(selectors, &ambient_selector(&1, source))

  defp ambient_orders(value, source) do
    raise "#{source}: orders in [ambient] must be \"all\" or a list of selectors, " <>
            "got #{inspect(value)}"
  end

  defp ambient_selector(table, source) when is_map(table) and map_size(table) == 1 do
    [{key, value}] = Map.to_list(table)

    cond do
      key not in @ambient_selectors ->
        raise "#{source}: unknown selector #{inspect(key)} in [ambient] orders " <>
                "(one of #{Enum.join(@ambient_selectors, ", ")})"

      not is_binary(value) ->
        raise "#{source}: #{key} in [ambient] orders must be a string, got #{inspect(value)}"

      key == "repo" ->
        {:repo, value}

      true ->
        {String.to_atom(key), String.to_atom(value)}
    end
  end

  defp ambient_selector(table, source) do
    raise "#{source}: each [ambient] orders selector takes exactly one key, " <>
            "got #{inspect(table)} (selectors are OR'd, so two keys would widen " <>
            "the opt-in rather than narrow it)"
  end

  defp convert(table, allowed, source, section) do
    Enum.map(table, fn {key, value} ->
      case Map.fetch(allowed, key) do
        {:ok, atom} -> {atom, value}
        :error -> raise "#{source}: unknown key #{inspect(key)} in [#{section}]"
      end
    end)
  end
end
