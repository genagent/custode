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

  Concurrent provisioning is safe within a node and across OS processes.
  Callers on one node are serialized with `:global.trans/4`. Creation from a
  missing file writes a temporary file and publishes it with a same-directory
  hard link, which fails with `:eexist` when another process won; the loser
  reads the winner's file. Replacing a malformed file is two steps (remove,
  then link), which two processes could interleave into two identities, so
  only that recovery takes an OS-level exclusive lock file (`<file>.lock`,
  created with `O_CREAT|O_EXCL`). The file is read again once the lock is
  held: a valid id is returned unchanged, a missing file is created, and only
  a still-malformed file is removed and replaced. The lock is released
  afterwards. A lock file is never broken automatically, because breaking one
  would reintroduce the race. If it stays held past a bounded wait,
  `provision/0` returns `{:error, :recovery_locked}` and logs a warning, and a
  leftover installation lock file beside the database has to be removed by
  hand. Neither the error nor the log names the path.
  """

  require Logger

  @key {__MODULE__, :id}
  @prefix "inst_"
  @random_bytes 16
  @lock_wait_ms 5_000
  @lock_poll_ms 50

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
  # Local callers serialize per path with `:global.trans/4`; `retries` bounds
  # the wait for that lock and production waits indefinitely. `:global` only
  # covers one node, so recovery of a malformed file also takes an OS-level
  # exclusive lock file, re-reads under it, and never breaks it (see the
  # moduledoc). Creation from a missing file needs no lock: publication uses a
  # same-directory hard link, which creates the destination without replacing a
  # concurrent winner.
  #
  # `opts` are test seams:
  #   * `:lock_wait_ms` / `:lock_poll_ms` - bound and interval of the wait for
  #     the recovery lock file
  #   * `:before_lock` - a function run after the first malformed read and
  #     before the recovery lock is requested
  #   * `:publish` - the publish function used during recovery
  @spec id_at(Path.t(), non_neg_integer() | :infinity, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def id_at(path, retries \\ :infinity, opts \\ []) do
    path = Path.expand(path)
    lock_id = {{__MODULE__, path}, self()}

    case :global.trans(
           lock_id,
           fn -> id_at_locked(path, opts) end,
           [node() | Node.list()],
           retries
         ) do
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

  defp id_at_locked(path, opts) do
    case read(path) do
      {:ok, id} -> {:ok, id}
      {:error, :enoent} -> create_at(path)
      {:error, :malformed} -> recover_malformed(path, opts)
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

  # Another OS process may be recovering the same file, so the remove and the
  # link happen under an exclusive lock file, and the file is read again once
  # the lock is held: whoever got there first has already fixed it.
  defp recover_malformed(path, opts) do
    publish = Keyword.get(opts, :publish, &File.ln/2)
    Keyword.get(opts, :before_lock, fn -> :ok end).()

    with_recovery_lock(path, opts, fn ->
      case read(path) do
        {:ok, id} -> {:ok, id}
        {:error, :enoent} -> create_at(path, publish)
        {:error, :malformed} -> replace_malformed(path, publish)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp replace_malformed(path, publish) do
    Logger.warning("installation id file is malformed; replacing it")

    case File.rm(path) do
      :ok -> create_at(path, publish)
      {:error, :enoent} -> create_at(path, publish)
      {:error, reason} -> {:error, reason}
    end
  end

  # The lock is a file created with O_CREAT|O_EXCL. It is never broken here: a
  # holder that died leaves it behind and it has to be removed by hand, because
  # breaking it automatically would let two recoveries run at once. Neither the
  # error nor the log carries the path.
  defp with_recovery_lock(path, opts, fun) do
    lock = path <> ".lock"
    wait = Keyword.get(opts, :lock_wait_ms, @lock_wait_ms)
    poll = Keyword.get(opts, :lock_poll_ms, @lock_poll_ms)

    case acquire_lock(lock, System.monotonic_time(:millisecond) + wait, poll) do
      {:ok, io} ->
        try do
          fun.()
        after
          File.close(io)
          File.rm(lock)
        end

      :timeout ->
        Logger.warning(
          "installation recovery lock is still held; a leftover installation " <>
            "lock file beside the database must be removed by hand"
        )

        {:error, :recovery_locked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_lock(lock, deadline, poll) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        {:ok, io}

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(poll)
          acquire_lock(lock, deadline, poll)
        end

      {:error, reason} ->
        {:error, reason}
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
