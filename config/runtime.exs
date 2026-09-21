import Config

# Custode home (#41 / design 001 slice 5): with $CUSTODE_HOME set, every
# relative runtime path roots under it -- db, MCP config dir, feed mirror --
# so an installed custode keeps ALL state in one directory. Unset, the cwd
# serves, exactly the source-repo behavior. Rooted here (not config.exs) so
# releases work and the merge is the normal runtime one.
if config_env() != :test do
  config :custode, Custode.Repo,
    database: Custode.Home.resolve_in(&Custode.Home.data_dir/0, "custode.db")

  config :custode,
    mcp_config_dir: Custode.Home.resolve_in(&Custode.Home.runtime_dir/0, "tmp"),
    feed_path: Custode.Home.resolve_in(&Custode.Home.data_dir/0, "feed.jsonl")

  # routines.toml (#41 / design 001): when a routines file exists it is the
  # whole roster and wins outright over the config.exs lists (D1: never
  # merged). `config/2` (not put_env) so the values land through the normal
  # runtime-config merge.
  case Custode.Config.Loader.load() do
    {:ok, path, routines, sensors, profiles} ->
      IO.puts("custode: roster loaded from #{path}")
      config :custode, routines: routines, sensors: sensors

      # profiles ride the same file (#236), but only override the config.exs
      # defaults when the file actually declares a [[profiles]] section. A
      # legacy roster (routines only, no profiles) must NOT wipe the config
      # profiles its routines inherit from -- that would crash the boot.
      if map_size(profiles) > 0 do
        config :custode, profiles: profiles
      end

    # No local roster (#530): the fleet is empty, and says so. It used to
    # fall back to a roster checked into config.exs, which was one person's.
    :no_file ->
      IO.puts(
        "custode: no routines.toml found, the fleet is empty " <>
          "(cp routines.example.toml routines.toml, or add an agent from /console)"
      )
  end

  # custode.toml (#267 / design 003 slice 2): the operator config beyond the
  # roster -- [fleet], [janitor], [advisors], [server] and [ambient].
  # Per-section wins-outright over the exs defaults; absent file is a no-op.
  custode_config =
    case Custode.Config.CustodeToml.load() do
      {:ok, custode_path, [_ | _] = custode_config} ->
        IO.puts("custode: config loaded from #{custode_path}")
        config :custode, custode_config
        custode_config

      _none ->
        []
    end

  # The port the endpoint actually binds: config.exs's default unless
  # [server] dashboard_port moved it. #65's check_origin below must name it.
  dashboard_port = Custode.Config.CustodeToml.dashboard_port(custode_config, 4646)

  # Tailnet exposure (#65): CUSTODE_PUBLIC_HOST is the ts.net hostname that
  # `tailscale serve --bg http://127.0.0.1:4646` publishes. The endpoint
  # stays bound to loopback exactly as before -- tailscale is the proxy and
  # the tailnet is the auth boundary -- but the LiveView websocket must
  # accept the proxied origin, links must generate against the public host,
  # and phone notifications must deep-link somewhere the phone can reach.
  if public_host = System.get_env("CUSTODE_PUBLIC_HOST") do
    demo_key? = System.get_env("CUSTODE_SECRET_KEY_BASE") in [nil, ""]

    if demo_key? do
      raise """
      CUSTODE_PUBLIC_HOST is set but CUSTODE_SECRET_KEY_BASE is not.
      The checked-in demo secret_key_base signs the LiveView session and
      must never leave localhost. Generate one (mix phx.gen.secret) and
      export CUSTODE_SECRET_KEY_BASE before exposing the dashboard.
      """
    end

    config :custode, CustodeWeb.Endpoint,
      url: [host: public_host, scheme: "https", port: 443],
      check_origin: [
        "https://#{public_host}",
        "http://localhost:#{dashboard_port}",
        "http://127.0.0.1:#{dashboard_port}"
      ]

    config :custode, dashboard_base_url: "https://#{public_host}"
  end

  if secret_key_base = System.get_env("CUSTODE_SECRET_KEY_BASE") do
    config :custode, CustodeWeb.Endpoint, secret_key_base: secret_key_base
  end
end
