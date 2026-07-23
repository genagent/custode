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

  This module currently loads the SCALAR sections:

    * `[fleet]` -- timezone, model, max_budget_usd, daily_budget_usd
    * `[janitor]` -- feed_days, subagent_ttl_s

  The `[server]` (endpoint port + basic auth, #65) and `[ambient]` (orders)
  sections are recognized-but-deferred: a `custode.toml` may carry them
  without failing the boot, but they are not applied yet (the rest of #267).
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

  # known sections not yet applied (the rest of #267)
  @deferred ~w(server ambient)

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

  defp convert_section("fleet", table, source), do: convert(table, @fleet, source, "fleet")

  defp convert_section("janitor", table, source),
    do: [{:janitor, convert(table, @janitor, source, "janitor")}]

  defp convert_section(section, _table, _source) when section in @deferred do
    IO.puts("custode: [#{section}] in custode.toml is not applied yet (part of #267)")
    []
  end

  defp convert_section(section, _table, source) do
    raise "#{source}: unknown [#{section}] section in custode.toml"
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
