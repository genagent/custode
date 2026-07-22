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
    {:ok, path, routines, sensors} ->
      IO.puts("custode: roster loaded from #{path}")
      config :custode, routines: routines, sensors: sensors

    :no_file ->
      :ok
  end
end
