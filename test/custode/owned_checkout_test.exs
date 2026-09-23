defmodule Custode.OwnedCheckoutTest do
  use ExUnit.Case, async: true

  alias Custode.OwnedCheckout

  setup do
    root = Path.join(System.tmp_dir!(), "custode-owned-checkout-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "path/2" do
    test "derives one deterministic path below the data root", %{root: root} do
      assert OwnedCheckout.path("redis-steward", root: root) ==
               {:ok, Path.join([root, "checkouts", "redis-steward"])}
    end

    test "refuses ids that could escape or collide after sanitizing", %{root: root} do
      for id <- ["", ".", "..", "../elsewhere", "owner/repo", "/absolute", "two words"] do
        assert OwnedCheckout.path(id, root: root) == {:error, :invalid_routine_id}
      end
    end
  end

  describe "inspect_destination/2" do
    test "distinguishes missing and empty destinations", %{root: root} do
      missing = Path.join(root, "missing")
      empty = Path.join(root, "empty")
      File.mkdir_p!(empty)

      assert {:ok, %{state: :missing, path: ^missing, reason: nil}} =
               OwnedCheckout.inspect_destination(missing, "acme/widgets")

      assert {:ok, %{state: :empty, path: ^empty, reason: nil}} =
               OwnedCheckout.inspect_destination(empty, "acme/widgets")
    end

    test "marks files, symlinks and non-repository directories as occupied", %{root: root} do
      file = Path.join(root, "file")
      link = Path.join(root, "link")
      directory = Path.join(root, "directory")
      File.write!(file, "occupied")
      File.ln_s!(file, link)
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "content"), "occupied")

      assert {:ok, %{state: :occupied, reason: :not_a_directory}} =
               OwnedCheckout.inspect_destination(file, "acme/widgets")

      assert {:ok, %{state: :occupied, reason: :not_a_directory}} =
               OwnedCheckout.inspect_destination(link, "acme/widgets")

      assert {:ok, %{state: :occupied, reason: :not_a_repository}} =
               OwnedCheckout.inspect_destination(directory, "acme/widgets")
    end

    test "does not mistake a directory nested inside another repository for its root", %{
      root: root
    } do
      repository = Path.join(root, "repository")
      nested = Path.join(repository, "nested")
      init_repository!(repository, "https://github.com/acme/widgets.git")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "content"), "occupied")

      assert {:ok, %{state: :occupied, reason: :not_repository_root}} =
               OwnedCheckout.inspect_destination(nested, "acme/widgets")
    end

    test "accepts common GitHub HTTPS and SSH origins without network access", %{root: root} do
      origins = [
        "https://github.com/acme/widgets.git",
        "git@github.com:acme/widgets.git",
        "ssh://git@github.com/acme/widgets.git"
      ]

      for {origin, index} <- Enum.with_index(origins) do
        repository = Path.join(root, "matching-#{index}")
        init_repository!(repository, origin)

        assert {:ok,
                %{
                  state: :matching,
                  expected_repo: "ACME/Widgets",
                  observed_repo: "acme/widgets",
                  reason: nil
                }} = OwnedCheckout.inspect_destination(repository, "ACME/Widgets")
      end
    end

    test "reports a different GitHub origin without exposing the raw URL", %{root: root} do
      repository = Path.join(root, "mismatched")
      init_repository!(repository, "https://github.com/elsewhere/other.git")

      assert {:ok,
              %{
                state: :mismatched,
                expected_repo: "acme/widgets",
                observed_repo: "elsewhere/other",
                reason: :repository_mismatch
              } = inspection} = OwnedCheckout.inspect_destination(repository, "acme/widgets")

      refute Map.has_key?(inspection, :origin)
    end

    test "reports missing and unrecognized origins as mismatches", %{root: root} do
      missing_origin = Path.join(root, "missing-origin")
      local_origin = Path.join(root, "local-origin")
      init_repository!(missing_origin)
      init_repository!(local_origin, Path.join(root, "private-token-shaped-location"))

      assert {:ok, %{state: :mismatched, observed_repo: nil, reason: :origin_missing}} =
               OwnedCheckout.inspect_destination(missing_origin, "acme/widgets")

      assert {:ok, %{state: :mismatched, observed_repo: nil, reason: :origin_unrecognized}} =
               OwnedCheckout.inspect_destination(local_origin, "acme/widgets")
    end

    test "rejects malformed expected repository names", %{root: root} do
      assert OwnedCheckout.inspect_destination(root, "not-owner-name") ==
               {:error, :invalid_repository}
    end
  end

  describe "repository_from_origin/1" do
    test "rejects other hosts and repository-shaped extra path segments" do
      assert OwnedCheckout.repository_from_origin("https://example.com/acme/widgets.git") ==
               {:error, :unrecognized_origin}

      assert OwnedCheckout.repository_from_origin("https://github.com/acme/widgets/extra.git") ==
               {:error, :unrecognized_origin}
    end
  end

  defp init_repository!(path, origin \\ nil) do
    File.mkdir_p!(path)
    git!(path, ["init", "--quiet"])
    if origin, do: git!(path, ["remote", "add", "origin", origin])
    path
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
