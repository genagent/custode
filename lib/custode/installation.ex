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
  # Local callers serialize per path. Publication uses a same-directory hard
  # link, which creates the destination without replacing a concurrent winner.
  @spec id_at(Path.t()) :: String.t()
  def id_at(path) do
    path = Path.expand(path)
    lock_id = {{__MODULE__, path}, self()}

    case :global.trans(lock_id, fn -> id_at_locked(path) end) do
      {:aborted, reason} -> unpersisted_id({:lock_aborted, reason})
      id -> id
    end
  end

  @doc false
  @spec create_at(Path.t(), (Path.t(), Path.t() -> :ok | {:error, term()})) :: String.t()
  def create_at(path, publish \\ &File.ln/2) when is_function(publish, 2) do
    id = generate()
    temp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4))

    with_temp_file(temp, fn ->
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, id <> "\n") do
        resolve_publication(path, id, publish.(temp, path))
      else
        {:error, reason} -> unpersisted_id(reason, id)
      end
    end)
  end

  defp id_at_locked(path) do
    case read(path) do
      {:ok, id} -> id
      {:error, :enoent} -> create_at(path)
      {:error, :malformed} -> replace_malformed(path)
      {:error, reason} -> unpersisted_id(reason)
    end
  end

  defp read(path) do
    with {:ok, contents} <- File.read(path),
         id = String.trim(contents),
         true <- valid?(id) do
      {:ok, id}
    else
      false -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_malformed(path) do
    Logger.warning("installation id file is malformed; replacing it")

    case File.rm(path) do
      :ok -> create_at(path)
      {:error, :enoent} -> create_at(path)
      {:error, reason} -> unpersisted_id(reason)
    end
  end

  defp resolve_publication(path, id, result) when result in [:ok, {:error, :eexist}] do
    case read(path) do
      {:ok, on_disk} -> on_disk
      {:error, reason} -> unpersisted_id(reason, id)
    end
  end

  defp resolve_publication(_path, id, {:error, reason}), do: unpersisted_id(reason, id)

  defp resolve_publication(_path, id, unexpected),
    do: unpersisted_id({:unexpected_publish_result, unexpected}, id)

  defp with_temp_file(temp, fun) do
    fun.()
  after
    File.rm(temp)
  end

  defp unpersisted_id(reason, id \\ generate()) do
    Logger.warning(
      "installation id could not be persisted (#{inspect(reason, limit: 3, printable_limit: 128)}); " <>
        "it is stable only until restart"
    )

    id
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
