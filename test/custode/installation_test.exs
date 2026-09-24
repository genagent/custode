defmodule Custode.InstallationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ExUnit.CaptureLog

  alias Custode.Installation

  # Callers released together per round, and rounds per starting state. Sixty
  # four processes hitting the same path is far past the two the old
  # rename-based publication needed to return different ids.
  @callers 64
  @rounds 5

  setup do
    dir = Path.join(System.tmp_dir!(), uid("custode-installation"))
    File.mkdir_p!(dir)

    # These tests provision and forget the cache the app filled at boot; put it
    # back so no other module sees a changed identity.
    booted = Installation.fetch()

    on_exit(fn ->
      Installation.restore(booted)
      File.rm_rf!(dir)
    end)

    %{path: Path.join(dir, "custode.db.installation"), booted: booted}
  end

  describe "boot provisioning" do
    test "the app provisioned an id and persisted it beside the configured database", %{
      booted: booted
    } do
      assert {:ok, "inst_" <> _rest = id} = booted
      assert Installation.fetch() == {:ok, id}

      database = :custode |> Application.get_env(Custode.Repo) |> Keyword.fetch!(:database)

      assert File.read!(Path.expand(database) <> ".installation") == id <> "\n"
    end

    test "provision/0 returns the id already on disk, so a restart keeps it", %{booted: booted} do
      assert {:ok, id} = booted

      Installation.forget()
      assert Installation.fetch() == {:error, :not_provisioned}

      assert Installation.provision() == {:ok, id}
      assert Installation.fetch() == {:ok, id}
    end
  end

  describe "fetch/0" do
    test "returns :not_provisioned and creates nothing when the cache is empty", %{path: path} do
      Installation.forget()

      assert Installation.fetch() == {:error, :not_provisioned}
      assert Installation.fetch() == {:error, :not_provisioned}
      refute File.exists?(path)
    end

    test "does no file I/O: a provisioned id survives its file being deleted", %{path: path} do
      assert {:ok, id} = Installation.provision_at(path)
      File.rm!(path)

      assert Installation.fetch() == {:ok, id}
      refute File.exists?(path)
    end
  end

  describe "provision_at/1" do
    test "persists the id, caches it and returns it", %{path: path} do
      assert {:ok, "inst_" <> _rest = id} = Installation.provision_at(path)

      assert File.read!(path) == id <> "\n"
      assert Installation.fetch() == {:ok, id}
    end

    test "caches nothing when the id cannot be persisted", %{path: path} do
      File.mkdir_p!(path)

      Installation.forget()
      assert {:error, _reason} = Installation.provision_at(path)
      assert Installation.fetch() == {:error, :not_provisioned}
    end

    test "leaves a previously cached id in place when a later attempt fails", %{
      path: path,
      booted: {:ok, id}
    } do
      File.mkdir_p!(path)

      assert {:error, _reason} = Installation.provision_at(path)
      assert Installation.fetch() == {:ok, id}
    end
  end

  describe "id_at/1" do
    test "creates the file on first use and returns the same id afterwards", %{path: path} do
      refute File.exists?(path)

      assert {:ok, id} = Installation.id_at(path)

      assert String.starts_with?(id, "inst_")
      assert File.read!(path) == id <> "\n"
      assert Installation.id_at(path) == {:ok, id}
    end

    test "creates the parent directory when it is missing", %{path: path} do
      nested = Path.join([Path.dirname(path), "nested", "deeper", "custode.installation"])

      assert {:ok, "inst_" <> _rest} = Installation.id_at(nested)
      assert File.exists?(nested)
    end

    test "replaces a malformed file with a valid id", %{path: path} do
      for contents <- ["", "not-an-id\n", "inst_\n", "\n\n"] do
        File.write!(path, contents)

        assert {:ok, id} = capture_log_result(fn -> Installation.id_at(path) end)

        assert String.starts_with?(id, "inst_")
        assert byte_size(id) > byte_size("inst_")
        assert File.read!(path) == id <> "\n"
        assert Installation.id_at(path) == {:ok, id}
      end
    end

    test "a valid id installed by another process before the lock is kept, not replaced", %{
      path: path
    } do
      File.write!(path, "garbage\n")
      external = "inst_EXTERNAL"

      before_lock = fn ->
        temp = path <> ".external"
        File.write!(temp, external <> "\n")
        File.rename!(temp, path)
      end

      {result, log} =
        capture_result_and_log(fn ->
          Installation.id_at(path, :infinity, before_lock: before_lock)
        end)

      assert result == {:ok, external}
      assert File.read!(path) == external <> "\n"
      refute log =~ "replacing"
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "a publisher that wins during recovery is returned, not overwritten", %{path: path} do
      File.write!(path, "garbage\n")
      external = "inst_EXTERNAL"

      publish = fn temp, dest ->
        winner = dest <> ".external"
        File.write!(winner, external <> "\n")
        :ok = File.ln(winner, dest)
        File.rm!(winner)
        File.ln(temp, dest)
      end

      assert {:ok, ^external} =
               capture_log_result(fn -> Installation.id_at(path, :infinity, publish: publish) end)

      assert File.read!(path) == external <> "\n"
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "a recovery lock held by someone else is never broken", %{path: path} do
      File.write!(path, "garbage\n")
      lock = path <> ".lock"
      File.write!(lock, "held")

      {result, log} =
        capture_result_and_log(fn ->
          Installation.id_at(path, :infinity, lock_wait_ms: 30, lock_poll_ms: 5)
        end)

      assert result == {:error, :recovery_locked}
      assert File.read!(path) == "garbage\n"
      assert File.read!(lock) == "held"
      assert log =~ "removed by hand"
      refute log =~ Path.dirname(path)
    end

    test "leaves no lock file behind after a recovery", %{path: path} do
      File.write!(path, "garbage\n")

      assert {:ok, id} = capture_log_result(fn -> Installation.id_at(path) end)

      assert File.read!(path) == id <> "\n"
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "returns an error when the path is a directory, and leaves it alone", %{path: path} do
      File.mkdir_p!(path)

      assert {:error, :eisdir} = Installation.id_at(path)
      assert File.dir?(path)
    end

    test "returns an error when the parent directory cannot be created", %{path: path} do
      # a regular file where the parent directory should be
      File.write!(Path.dirname(path) <> "/blocker", "x")
      nested = Path.join([Path.dirname(path), "blocker", "custode.installation"])

      assert {:error, _reason} = Installation.id_at(nested)
    end

    test "returns a lock error, and writes nothing, when the lock is held elsewhere", %{
      path: path
    } do
      parent = self()
      resource = {Installation, Path.expand(path)}

      holder =
        spawn_link(fn ->
          :global.set_lock({resource, self()}, [node()], :infinity)
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :locked, 5_000

      assert {:error, {:lock_aborted, _reason}} = Installation.id_at(path, 0)
      refute File.exists?(path)

      send(holder, :release)
    end
  end

  describe "first-call concurrency" do
    test "callers racing on a missing file all return the one persisted id", %{path: path} do
      for _round <- 1..@rounds do
        File.rm(path)

        results = race(path)

        assert_converged(results, path)
      end
    end

    test "callers racing on a malformed file all return the one replacement id", %{path: path} do
      for {contents, round} <- Enum.zip(Stream.cycle(["", "garbage\n", "inst_\n"]), 1..@rounds) do
        File.write!(path, contents)

        log = capture_log(fn -> assert_converged(race(path), path) end)

        # Exactly one caller replaced the file; the rest found its result.
        assert length(Regex.scan(~r/malformed/, log)) == 1,
               "round #{round}: expected one replacement, log was: #{log}"
      end
    end

    test "a valid file is never rewritten by racing callers", %{path: path} do
      assert {:ok, id} = Installation.id_at(path)
      %{inode: inode} = File.stat!(path)

      results = race(path)

      assert Enum.uniq(results) == [{:ok, id}]
      assert_converged(results, path)
      assert %{inode: ^inode} = File.stat!(path)
    end
  end

  describe "create_at/2" do
    test "loses a race to a writer outside this node and returns the winner", %{path: path} do
      winner = "inst_WINNER"

      publish = fn temp, dest ->
        File.write!(dest, winner <> "\n")
        File.ln(temp, dest)
      end

      assert Installation.create_at(path, publish) == {:ok, winner}
      assert File.read!(path) == winner <> "\n"
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "returns the publish error and leaves no temp file when publication fails", %{
      path: path
    } do
      assert Installation.create_at(path, fn _t, _d -> {:error, :eperm} end) ==
               {:error, :eperm}

      refute File.exists?(path)
      assert File.ls!(Path.dirname(path)) == []
    end

    test "returns an error for an unexpected publish result", %{path: path} do
      assert Installation.create_at(path, fn _t, _d -> :weird end) ==
               {:error, {:unexpected_publish_result, :weird}}

      assert File.ls!(Path.dirname(path)) == []
    end

    test "returns an error when the file cannot be read back after publication", %{path: path} do
      # publication reports success but leaves nothing valid at the destination
      assert {:error, :enoent} = Installation.create_at(path, fn _t, _d -> :ok end)
      assert File.ls!(Path.dirname(path)) == []
    end

    test "removes the temp file when publication raises", %{path: path} do
      assert_raise RuntimeError, "boom", fn ->
        Installation.create_at(path, fn _t, _d -> raise "boom" end)
      end

      assert File.ls!(Path.dirname(path)) == []
    end
  end

  # Runs `fun` under capture_log and returns its value, for a call whose log
  # is expected noise rather than the subject of the test.
  defp capture_log_result(fun) do
    {result, _log} = capture_result_and_log(fun)
    result
  end

  defp capture_result_and_log(fun) do
    parent = self()
    log = capture_log(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> {result, log}
    end
  end

  # Starts @callers processes, holds them at a barrier until every one is
  # alive, then releases them in one burst so their first read of the path
  # happens before any of them has written.
  defp race(path) do
    parent = self()

    tasks =
      for _ <- 1..@callers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Installation.id_at(path)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    Task.await_many(tasks, 60_000)
  end

  defp assert_converged(results, path) do
    assert length(results) == @callers

    assert [{:ok, id}] = Enum.uniq(results), "callers disagreed: #{inspect(Enum.uniq(results))}"
    assert String.starts_with?(id, "inst_")
    assert File.read!(path) == id <> "\n"
    # the id on disk is the id every caller returned, and nothing else is left
    assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
  end
end
