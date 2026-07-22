import Config

# routines.toml (#41 / design 001): when a routines file exists it is the
# whole roster and wins outright over the config.exs lists (D1: never
# merged). runtime.exs (not config.exs) so releases work -- no Mix at
# runtime, just a file read. `config/2` (not put_env) so the values land
# through the normal runtime-config merge.
if config_env() != :test do
  case Custode.Config.Loader.load() do
    {:ok, path, routines, sensors} ->
      IO.puts("custode: roster loaded from #{path}")
      config :custode, routines: routines, sensors: sensors

    :no_file ->
      :ok
  end
end
