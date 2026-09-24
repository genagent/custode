defmodule Custode.InstallationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Installation

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
end
