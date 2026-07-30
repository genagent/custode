defmodule Custode.Assets do
  @moduledoc """
  The one accessor for packaged prompt and recipe assets (#269, design/003 D4).

  Charter and role bodies are the fleet's code. They ship inside the release
  as `priv/prompts/*.md` and are read through here, so an Attempt can record
  exactly which text it ran rather than "whatever `Custode.Routine.Prompts`
  compiled to that day".

  ## Precedence, deterministic and in one place

      1. an explicit application-configuration override for that id
      2. `<config_dir>/prompts/<id>.md`, the operator's escape hatch
      3. the packaged default under `priv/prompts/<id>.md`

  First match wins and the search stops. `overrides_in_effect/0` names
  everything not resolving to a packaged default, and the application logs it
  once at boot, so an override can never be silently in force.

  ## Declarative, not a second state store

  Assets are read, never written. Nothing here persists anything, and an
  asset is content plus an identity derived from that content. A caller that
  wants live per-Mission text wants a ContextBundle, not an asset.

  ## Versions are derived, never declared

  `version` is `"sha256:<digest>"` of the exact bytes. A version an author
  has to remember to bump is one that silently stops describing the file.
  Configuration MAY still declare an expected version, and a declared version
  that does not match the bytes is a startup error rather than a surprise at
  the next sweep. That is the only place "declared version" is meaningful:
  as an assertion about someone else's file.

  ## Substitution is placeholders, not code

  `render/2` replaces `{{name}}` with a caller-supplied binding. There is no
  expression evaluation and no logic, because the moment a prompt asset can
  compute, an operator override becomes a way to run code.
  """

  require Logger

  alias Custode.{Asset, Home}

  @prompt_ids ~w(
    charter
    assistant tutor caretaker repo_caretaker backlog_worker star_tracker
    contributor_watch quake_watch reviewer steward consistency_auditor
    sub_agent delegation
  )

  @media_type "text/markdown"

  @doc "Every prompt asset id the fleet expects to exist."
  @spec prompt_ids() :: [String.t()]
  def prompt_ids, do: @prompt_ids

  @doc "Resolve one asset through the precedence chain."
  @spec fetch(String.t()) :: {:ok, Asset.t()} | {:error, term()}
  def fetch(id) when is_binary(id) do
    case source(id) do
      {origin, path} -> read(id, origin, path)
      :missing -> {:error, {:asset_missing, id, searched(id)}}
    end
  end

  @doc "Resolve one asset or raise with the paths that were searched."
  @spec fetch!(String.t()) :: Asset.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, asset} -> asset
      {:error, reason} -> raise ArgumentError, message(reason)
    end
  end

  @doc """
  The asset content with `{{name}}` placeholders replaced.

  An unbound placeholder is left alone rather than blanked: a prompt that
  still visibly says `{{routine_id}}` is a bug someone will notice, and one
  quietly missing its routine id is a bug nobody will.
  """
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(id, bindings \\ %{}) do
    with {:ok, asset} <- fetch(id), do: {:ok, substitute(asset.content, bindings)}
  end

  @doc "render/2 or raise."
  @spec render!(String.t(), map()) :: String.t()
  def render!(id, bindings \\ %{}),
    do: id |> fetch!() |> Map.fetch!(:content) |> substitute(bindings)

  @doc "The reference shape for one asset, or an explicit unresolved marker."
  @spec reference(String.t()) :: map()
  def reference(id) do
    case fetch(id) do
      {:ok, asset} -> Asset.reference(asset)
      {:error, _reason} -> %{"kind" => "packaged_asset", "id" => id, "status" => "unresolved"}
    end
  end

  @doc """
  Validate every expected asset: present, valid UTF-8, and matching any
  version configuration declared for it.

  Returns `:ok` or `{:error, problems}` where each problem names the id and
  what is wrong with it, so a boot failure says which file to go look at.
  """
  @spec verify() :: :ok | {:error, [map()]}
  def verify do
    problems =
      @prompt_ids
      |> Enum.map(&problem/1)
      |> Enum.reject(&is_nil/1)

    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc "Every asset not resolving to its packaged default, for the boot log."
  @spec overrides_in_effect() :: [map()]
  def overrides_in_effect do
    for id <- @prompt_ids,
        {:ok, asset} <- [fetch(id)],
        asset.origin != :packaged,
        do: %{id: id, origin: asset.origin, path: asset.path, version: asset.version}
  end

  @doc """
  Log any override once at boot (design/003 D4), and surface a verification
  failure loudly.

  The fleet's own brain gets the same treatment ambient orders get: an
  override that changes how every sweep thinks should never be invisible.
  """
  @spec report() :: :ok
  def report do
    case verify() do
      :ok -> :ok
      {:error, problems} -> Logger.error("prompt assets invalid: #{inspect(problems)}")
    end

    for %{id: id, origin: origin, path: path} <- overrides_in_effect() do
      Logger.info("prompt asset override in effect: #{id} from #{origin} at #{path}")
    end

    :ok
  end

  defp problem(id) do
    case fetch(id) do
      {:ok, _asset} -> nil
      {:error, reason} -> %{id: id, reason: message(reason)}
    end
  end

  defp read(id, origin, path) do
    case File.read(path) do
      {:ok, content} -> validated(id, origin, path, content)
      {:error, posix} -> {:error, {:asset_unreadable, id, path, posix}}
    end
  end

  defp validated(id, origin, path, content) do
    digest = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    version = "sha256:" <> digest

    cond do
      not String.valid?(content) ->
        {:error, {:asset_not_utf8, id, path}}

      declared(id) not in [nil, version] ->
        {:error, {:asset_version_mismatch, id, path, declared(id), version}}

      true ->
        {:ok,
         %Asset{
           id: id,
           version: version,
           digest: digest,
           media_type: @media_type,
           origin: origin,
           path: path,
           content: content
         }}
    end
  end

  defp source(id) do
    configured = configured_path(id)
    config_dir_file = Path.join([Home.config_dir(), "prompts", id <> ".md"])
    packaged = packaged_path(id)

    cond do
      is_binary(configured) -> {:config, configured}
      File.regular?(config_dir_file) -> {:config_dir, config_dir_file}
      File.regular?(packaged) -> {:packaged, packaged}
      true -> :missing
    end
  end

  defp searched(id) do
    [
      configured_path(id),
      Path.join([Home.config_dir(), "prompts", id <> ".md"]),
      packaged_path(id)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Resolved at runtime, never at compile time: a release's priv directory is
  # not the build tree's, and baking the build path is how an asset that
  # exists in development goes missing in the binary.
  defp packaged_path(id), do: Application.app_dir(:custode, ["priv", "prompts", id <> ".md"])

  defp configured_path(id), do: id |> declaration() |> Keyword.get(:path)
  defp declared(id), do: id |> declaration() |> Keyword.get(:version)

  defp declaration(id) do
    :custode
    |> Application.get_env(:prompt_assets, %{})
    |> Map.get(id, [])
    |> List.wrap()
  end

  defp substitute(content, bindings) when map_size(bindings) == 0, do: content

  defp substitute(content, bindings) do
    Enum.reduce(bindings, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp message({:asset_missing, id, searched}),
    do: "prompt asset #{id} not found; searched #{Enum.join(searched, ", ")}"

  defp message({:asset_unreadable, id, path, posix}),
    do: "prompt asset #{id} at #{path} could not be read (#{:file.format_error(posix)})"

  defp message({:asset_not_utf8, id, path}),
    do: "prompt asset #{id} at #{path} is not valid UTF-8"

  defp message({:asset_version_mismatch, id, path, declared, actual}),
    do:
      "prompt asset #{id} at #{path} declares #{declared} but its content is #{actual}; " <>
        "update the declared version or restore the expected content"
end
