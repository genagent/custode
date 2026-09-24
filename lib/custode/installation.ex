defmodule Custode.Installation do
  @moduledoc """
  A stable, non-secret identity for this Custode installation (#647).

  An external operator session needs to know WHICH instance it reached, and to
  recognize the same one again after a restart or a reconnect. The id is random,
  written once to a file beside the database (`<database>.installation`) and
  cached in `:persistent_term`. It carries no information about the host, the
  Custode home, or any credential, and this module never returns the file's
  path: `id/0` returns the id and nothing else.

  The file lives beside the database, so a backup or a move of the database
  directory carries the identity with it, and two homes get two identities.
  """

  require Logger

  @key {__MODULE__, :id}
  @prefix "inst_"
  @random_bytes 16

  @doc "The installation id, created on first use."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      nil ->
        id = id_at(file_path())
        :persistent_term.put(@key, id)
        id

      id ->
        id
    end
  end

  @doc false
  # The file logic with the path injected, so a test can use a temporary one.
  # Reads a valid id, otherwise writes a new one atomically and returns what is
  # on disk afterwards, so two racing first callers agree on one id.
  @spec id_at(Path.t()) :: String.t()
  def id_at(path) do
    case read(path) do
      {:ok, id} -> id
      :error -> create(path)
    end
  end

  defp read(path) do
    with {:ok, contents} <- File.read(path),
         id = String.trim(contents),
         true <- valid?(id) do
      {:ok, id}
    else
      _missing_or_malformed -> :error
    end
  end

  defp create(path) do
    id = generate()
    temp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, id <> "\n"),
         :ok <- File.rename(temp, path) do
      case read(path) do
        {:ok, on_disk} -> on_disk
        :error -> id
      end
    else
      {:error, reason} ->
        File.rm(temp)

        Logger.warning(
          "installation id could not be persisted (#{inspect(reason)}); " <>
            "it is stable only until restart"
        )

        id
    end
  end

  defp generate,
    do: @prefix <> Base.encode32(:crypto.strong_rand_bytes(@random_bytes), padding: false)

  defp valid?(id), do: String.starts_with?(id, @prefix) and byte_size(id) > byte_size(@prefix)

  defp file_path do
    database =
      :custode
      |> Application.get_env(Custode.Repo, [])
      |> Keyword.get(:database, "custode.db")

    Path.expand(database) <> ".installation"
  end
end
