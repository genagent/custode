defmodule Custode.OwnedCheckoutTest do
  use ExUnit.Case, async: true

  alias Custode.OwnedCheckout
  alias Custode.OwnedCheckout.GitHubCloneRunner

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

  describe "provision/3" do
    test "provisions missing and empty destinations from local fixture remotes", %{root: root} do
      remote = bare_repository!(root)

      for {id, prepare} <- [{"missing", fn _path -> :ok end}, {"empty", &File.mkdir_p!/1}] do
        {:ok, destination} = OwnedCheckout.path(id, root: root)
        prepare.(destination)

        assert {:ok, %{status: :provisioned, path: ^destination, repo: "acme/widgets"}} =
                 OwnedCheckout.provision(id, "acme/widgets",
                   root: root,
                   clone: local_clone(remote)
                 )

        assert {:ok, %{state: :matching}} =
                 OwnedCheckout.inspect_destination(destination, "acme/widgets")
      end
    end

    test "a matching destination is idempotent and does not invoke the runner", %{root: root} do
      {:ok, destination} = OwnedCheckout.path("matching", root: root)
      init_repository!(destination, "https://github.com/acme/widgets.git")

      clone = fn _repo, _path -> flunk("matching repository must not be cloned again") end

      assert {:ok, %{status: :already_provisioned, path: ^destination}} =
               OwnedCheckout.provision("matching", "acme/widgets", root: root, clone: clone)
    end

    test "occupied and mismatched destinations are refused without mutation", %{root: root} do
      {:ok, occupied} = OwnedCheckout.path("occupied", root: root)
      {:ok, mismatched} = OwnedCheckout.path("mismatched", root: root)
      File.mkdir_p!(occupied)
      marker = Path.join(occupied, "keep")
      File.write!(marker, "operator data")
      init_repository!(mismatched, "https://github.com/elsewhere/other.git")

      clone = fn _repo, _path -> flunk("refused destination must not be cloned") end

      assert {:error, %{kind: :destination_refused, inspection: %{state: :occupied}}} =
               OwnedCheckout.provision("occupied", "acme/widgets", root: root, clone: clone)

      assert File.read!(marker) == "operator data"

      assert {:error, %{kind: :destination_refused, inspection: %{state: :mismatched}}} =
               OwnedCheckout.provision("mismatched", "acme/widgets", root: root, clone: clone)
    end

    test "clone and authentication failures are structured without raw output", %{root: root} do
      assert {:error,
              %{
                kind: :clone_failed,
                reason: :unknown,
                repo: "private/widgets"
              } = failure} =
               OwnedCheckout.provision("private", "private/widgets",
                 root: root,
                 clone: fn _repo, _path ->
                   {:error, {:secret_output, "token ghp_do-not-return"}}
                 end
               )

      refute inspect(failure) =~ "ghp_do-not-return"

      assert {:error, %{kind: :clone_failed, reason: :authentication_failed}} =
               OwnedCheckout.provision("private-auth", "private/widgets",
                 root: root,
                 clone: fn _repo, _path -> {:error, :authentication_failed} end
               )
    end

    test "a clone that does not produce the expected repository fails its postcondition", %{
      root: root
    } do
      clone = fn _repo, destination ->
        init_repository!(destination, "https://github.com/elsewhere/other.git")
        :ok
      end

      assert {:error,
              %{
                kind: :postcondition_failed,
                inspection: %{state: :mismatched, observed_repo: "elsewhere/other"}
              }} =
               OwnedCheckout.provision("wrong", "acme/widgets", root: root, clone: clone)
    end

    test "concurrent calls serialize one clone and the follower observes its result", %{
      root: root
    } do
      remote = bare_repository!(root)
      parent = self()

      clone = fn repo, destination ->
        send(parent, {:clone_started, self()})

        receive do
          :continue -> local_clone(remote).(repo, destination)
        end
      end

      calls =
        for _index <- 1..2 do
          Task.async(fn ->
            OwnedCheckout.provision("serialized", "acme/widgets", root: root, clone: clone)
          end)
        end

      assert_receive {:clone_started, runner}, 1_000
      refute_receive {:clone_started, _second}, 100
      send(runner, :continue)

      results = Enum.map(calls, &Task.await(&1, 2_000))
      assert Enum.count(results, &match?({:ok, %{status: :provisioned}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{status: :already_provisioned}}, &1)) == 1
      refute_receive {:clone_started, _second}
    end
  end

  describe "GitHubCloneRunner.clone/3" do
    test "uses an argv command and classifies authentication output without returning it" do
      parent = self()

      command = fn executable, args, opts ->
        send(parent, {:command, executable, args, opts})
        {"authentication failed for ghp_do-not-return", 1}
      end

      assert GitHubCloneRunner.clone("acme/widgets", "/tmp/destination", command: command) ==
               {:error, :authentication_failed}

      assert_receive {:command, "gh", ["repo", "clone", "acme/widgets", "/tmp/destination"],
                      [stderr_to_stdout: true]}

      assert GitHubCloneRunner.clone("acme/widgets", "/tmp/destination",
               command: fn _executable, _args, _opts ->
                 {"fatal: token ghp_do-not-return was rejected", 128}
               end
             ) == {:error, {:exit_status, 128}}
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

  defp bare_repository!(root) do
    path = Path.join(root, "fixture.git")
    File.mkdir_p!(path)
    git!(path, ["init", "--bare", "--quiet"])
    path
  end

  defp local_clone(remote) do
    fn _repo, destination ->
      case System.cmd("git", ["clone", "--quiet", remote, destination], stderr_to_stdout: true) do
        {_output, 0} ->
          git!(destination, ["remote", "set-url", "origin", "https://github.com/acme/widgets.git"])

          :ok

        {_output, _status} ->
          {:error, :runner_failed}
      end
    end
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
