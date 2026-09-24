defmodule Custode.Installation do
  @moduledoc """
  A stable, non-secret identity for this Custode installation (#647).

  An external operator session needs to know WHICH instance it reached, and to
  recognize the same one again after a restart or a reconnect. The id is random,
  written once to a file beside the database (`<database>.installation`) and
  cached in `:persistent_term`. It carries no information about the host, the
  Custode home, or any credential, and this module never returns the file's
  path.

  The id is provisioned at boot (`provision/0`, called from
  `Custode.Application`), the only place that may create or replace the file.
  Every reader goes through `fetch/0`, which reads the cache and does no file
  I/O, so a read-only surface such as `operator_bootstrap` can never write to
  disk. An id that could not be persisted is never returned or cached: a
  failed `provision/0` leaves `fetch/0` at `{:error, :not_provisioned}`, so the
  id a caller sees is always one that survives a restart.

  The file lives beside the database, so a backup or a move of the database
  directory carries the identity with it, and two homes get two identities.
  """

  require Logger

  @key {__MODULE__, :id}
  @prefix "inst_"
  @random_bytes 16

  @doc """
  Read the file beside the configured database, creating it when it is missing
  or replacing it when it is malformed, and cache the id it holds.

  On error nothing is cached and the error is returned. Call it at boot, not
  from a read path.
  """
  @spec provision() :: {:ok, String.t()} | {:error, term()}
  def provision, do: provision_at(file_path())

  @doc false
  # `provision/0` with the path injected, so a test can use a temporary one.
  @spec provision_at(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def provision_at(path) do
    with {:ok, id} <- id_at(path) do
      :persistent_term.put(@key, id)
      {:ok, id}
    end
  end

  @doc """
  The provisioned installation id. Reads the cache only: no file is read,
  created or replaced.
  """
  @spec fetch() :: {:ok, String.t()} | {:error, :not_provisioned}
  def fetch do
    case :persistent_term.get(@key, nil) do
      nil -> {:error, :not_provisioned}
      id -> {:ok, id}
    end
  end

  @doc false
  # Test seam: return the cache to a state `fetch/0` reported earlier.
  @spec restore({:ok, String.t()} | {:error, :not_provisioned}) :: :ok
  def restore({:ok, id}), do: :persistent_term.put(@key, id)
  def restore({:error, :not_provisioned}), do: forget()

  @doc false
  # Test seam: leave the installation unprovisioned.
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  @doc false
  # The file logic with the path injected, so a test can use a temporary one.
  # Local callers serialize per path. Publication uses a same-directory hard
  # link, which creates the destination without replacing a concurrent winner.
  # `retries` bounds the wait for that lock; production waits indefinitely.
  @spec id_at(Path.t(), non_neg_integer() | :infinity) :: {:ok, String.t()} | {:error, term()}
  def id_at(path, retries \\ :infinity) do
    path = Path.expand(path)
    lock_id = {{__MODULE__, path}, self()}

    case :global.trans(lock_id, fn -> id_at_locked(path) end, [node() | Node.list()], retries) do
      :aborted -> {:error, {:lock_aborted, :aborted}}
      result -> result
    end
  end

  @doc false
  @spec create_at(Path.t(), (Path.t(), Path.t() -> :ok | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def create_at(path, publish \\ &File.ln/2) when is_function(publish, 2) do
    temp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4))

    with_temp_file(temp, fn ->
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, generate() <> "\n") do
        resolve_publication(path, publish.(temp, path))
      end
    end)
  end

  defp id_at_locked(path) do
    case read(path) do
      {:ok, id} -> {:ok, id}
      {:error, :enoent} -> create_at(path)
      {:error, :malformed} -> replace_malformed(path)
      {:error, reason} -> {:error, reason}
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
      {:error, reason} -> {:error, reason}
    end
  end

  # After publication the file is the truth, whether this caller or a
  # concurrent one created it, so return what is on disk.
  defp resolve_publication(path, result) when result in [:ok, {:error, :eexist}], do: read(path)
  defp resolve_publication(_path, {:error, reason}), do: {:error, reason}

  defp resolve_publication(_path, unexpected),
    do: {:error, {:unexpected_publish_result, unexpected}}

  defp with_temp_file(temp, fun) do
    fun.()
  after
    File.rm(temp)
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
