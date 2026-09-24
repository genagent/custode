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
    on_exit(fn -> File.rm_rf!(dir) end)

    %{path: Path.join(dir, "custode.db.installation")}
  end

  test "id_at/1 creates the file on first use and returns the same id afterwards", %{path: path} do
    refute File.exists?(path)

    id = Installation.id_at(path)

    assert String.starts_with?(id, "inst_")
    assert File.read!(path) == id <> "\n"
    assert Installation.id_at(path) == id
  end

  test "id_at/1 creates the parent directory when it is missing", %{path: path} do
    nested = Path.join([Path.dirname(path), "nested", "deeper", "custode.installation"])

    assert "inst_" <> _rest = Installation.id_at(nested)
    assert File.exists?(nested)
  end

  test "id_at/1 replaces a malformed file with a valid id", %{path: path} do
    for contents <- ["", "not-an-id\n", "inst_\n", "\n\n"] do
      File.write!(path, contents)

      id = Installation.id_at(path)

      assert String.starts_with?(id, "inst_")
      assert byte_size(id) > byte_size("inst_")
      assert File.read!(path) == id <> "\n"
      assert Installation.id_at(path) == id
    end
  end

  test "id/0 is stable across calls" do
    id = Installation.id()

    assert String.starts_with?(id, "inst_")
    assert Installation.id() == id
  end

  describe "first-call concurrency" do
    test "callers racing on a missing file all return the one persisted id", %{path: path} do
      for _round <- 1..@rounds do
        File.rm(path)

        ids = race(path)

        assert_converged(ids, path)
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
      id = Installation.id_at(path)
      %{inode: inode} = File.stat!(path)

      ids = race(path)

      assert Enum.uniq(ids) == [id]
      assert_converged(ids, path)
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

      assert Installation.create_at(path, publish) == winner
      assert File.read!(path) == winner <> "\n"
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "returns an unpersisted id, warns and leaves no temp file when publication fails", %{
      path: path
    } do
      log =
        capture_log(fn ->
          assert "inst_" <> _rest =
                   Installation.create_at(path, fn _t, _d -> {:error, :eperm} end)
        end)

      assert log =~ "could not be persisted"
      assert log =~ ":eperm"
      assert File.ls!(Path.dirname(path)) == []
    end

    test "removes the temp file when publication raises", %{path: path} do
      assert_raise RuntimeError, "boom", fn ->
        Installation.create_at(path, fn _t, _d -> raise "boom" end)
      end

      assert File.ls!(Path.dirname(path)) == []
    end

    test "id_at/1 warns and returns an unpersisted id when the path cannot be used", %{path: path} do
      # a directory where the file should be: neither valid, missing nor replaceable
      File.mkdir_p!(path)

      log = capture_log(fn -> assert "inst_" <> _rest = Installation.id_at(path) end)

      assert log =~ "could not be persisted"
      assert File.dir?(path)
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

  defp assert_converged(ids, path) do
    assert length(ids) == @callers

    assert [id] = Enum.uniq(ids), "callers disagreed: #{inspect(Enum.uniq(ids))}"
    assert String.starts_with?(id, "inst_")
    assert File.read!(path) == id <> "\n"
    # the id on disk is the id every caller returned, and nothing else is left
    assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
  end
end
