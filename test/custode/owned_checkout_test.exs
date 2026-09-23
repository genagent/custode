defmodule Custode.OwnedCheckoutTest do
  use ExUnit.Case, async: true

  alias Custode.OwnedCheckout
  alias Custode.OwnedCheckout.Barrier
  alias Custode.OwnedCheckout.GitHubCloneRunner
  alias Custode.OwnedCheckout.GitRefreshRunner

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

  describe "refresh/3" do
    test "fast-forwards the checked-out default branch and is then idempotent", %{root: root} do
      fixture = refresh_fixture!(root, "refresh")
      push_fixture_change!(fixture, "second\n")

      assert {:ok,
              %{
                status: :fast_forwarded,
                branch: "main",
                commits: 1,
                path: destination
              }} =
               OwnedCheckout.refresh("refresh", "acme/widgets",
                 root: root,
                 status: idle_status()
               )

      assert File.read!(Path.join(destination, "README.md")) == "second\n"

      assert {:ok, %{status: :up_to_date, commits: 0}} =
               OwnedCheckout.refresh("refresh", "acme/widgets",
                 root: root,
                 status: idle_status()
               )
    end

    test "refuses active routine states before fetching", %{root: root} do
      fixture = refresh_fixture!(root, "busy")
      parent = self()

      runner = fn path, args ->
        send(parent, {:git, args})
        GitRefreshRunner.run(path, args)
      end

      for state <- [:running, :paused, {:awaiting_permission, %{secret: "nope"}}] do
        assert {:error, %{kind: :routine_busy, state: expected_state}} =
                 OwnedCheckout.refresh("busy", "acme/widgets",
                   root: root,
                   status: fn _id -> {:ok, state} end,
                   runner: runner
                 )

        assert expected_state == Custode.state_of(state)
        refute_receive {:git, ["fetch", "origin"]}
      end

      assert File.read!(Path.join(fixture.destination, "README.md")) == "first\n"
    end

    test "refuses tracked and untracked changes without altering them", %{root: root} do
      fixture = refresh_fixture!(root, "dirty")
      readme = Path.join(fixture.destination, "README.md")
      note = Path.join(fixture.destination, "note.txt")
      File.write!(readme, "local\n")
      File.write!(note, "keep\n")

      assert {:error, %{kind: :dirty_checkout}} =
               OwnedCheckout.refresh("dirty", "acme/widgets",
                 root: root,
                 status: idle_status()
               )

      assert File.read!(readme) == "local\n"
      assert File.read!(note) == "keep\n"
    end

    test "refuses a non-default branch, detached head, and local history", %{root: root} do
      branch_fixture = refresh_fixture!(root, "branch")
      git!(branch_fixture.destination, ["switch", "-c", "feature"])

      assert {:error, %{kind: :branch_refused, current_branch: "feature", default_branch: "main"}} =
               OwnedCheckout.refresh("branch", "acme/widgets",
                 root: root,
                 status: idle_status()
               )

      detached_fixture = refresh_fixture!(root, "detached")
      git!(detached_fixture.destination, ["checkout", "--detach", "--quiet"])

      assert {:error, %{kind: :detached_head}} =
               OwnedCheckout.refresh("detached", "acme/widgets",
                 root: root,
                 status: idle_status()
               )

      ahead_fixture = refresh_fixture!(root, "ahead")
      commit_file!(ahead_fixture.destination, "local.txt", "local\n", "local")

      assert {:error, %{kind: :history_refused, ahead: 1, behind: 0}} =
               OwnedCheckout.refresh("ahead", "acme/widgets",
                 root: root,
                 status: idle_status()
               )
    end

    test "sanitizes fetch authentication failures", %{root: root} do
      _fixture = refresh_fixture!(root, "auth")

      runner = fn path, args ->
        if args == ["fetch", "origin"] do
          {:error, :authentication_failed}
        else
          GitRefreshRunner.run(path, args)
        end
      end

      assert {:error, %{kind: :fetch_failed, reason: :authentication_failed} = failure} =
               OwnedCheckout.refresh("auth", "acme/widgets",
                 root: root,
                 status: idle_status(),
                 runner: runner
               )

      refute inspect(failure) =~ "token"
    end

    test "the provider transition barrier waits for an in-progress refresh", %{root: root} do
      fixture = refresh_fixture!(root, "barrier")
      parent = self()

      runner = fn path, args ->
        if args == ["fetch", "origin"] do
          send(parent, {:fetch_started, self()})

          receive do
            :continue -> GitRefreshRunner.run(path, args)
          end
        else
          GitRefreshRunner.run(path, args)
        end
      end

      refresh =
        Task.async(fn ->
          OwnedCheckout.refresh("barrier", "acme/widgets",
            root: root,
            status: idle_status(),
            runner: runner
          )
        end)

      assert_receive {:fetch_started, refresher}, 1_000

      transition =
        Task.async(fn ->
          Barrier.synchronize_agent("barrier",
            root: root,
            routine: fn _id -> %{working_dir: fixture.destination} end
          )
        end)

      refute Task.yield(transition, 100)
      send(refresher, :continue)
      assert {:ok, %{status: :up_to_date}} = Task.await(refresh, 2_000)
      assert :ok = Task.await(transition, 2_000)
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

  defp idle_status, do: fn _id -> {:ok, :idle} end

  defp refresh_fixture!(root, id) do
    source = Path.join(root, "#{id}-source")
    remote = Path.join(root, "#{id}-remote.git")
    writer = Path.join(root, "#{id}-writer")
    {:ok, destination} = OwnedCheckout.path(id, root: root)

    File.mkdir_p!(source)
    git!(source, ["init", "--quiet", "--initial-branch=main"])
    configure_identity!(source)
    commit_file!(source, "README.md", "first\n", "first")
    git!(root, ["clone", "--bare", "--quiet", source, remote])
    git!(remote, ["symbolic-ref", "HEAD", "refs/heads/main"])
    git!(root, ["clone", "--quiet", remote, destination])
    git!(root, ["clone", "--quiet", remote, writer])
    configure_identity!(destination)
    configure_identity!(writer)

    github_origin = "https://github.com/acme/widgets.git"
    git!(destination, ["remote", "set-url", "origin", github_origin])
    git!(destination, ["config", "url.#{remote}.insteadOf", github_origin])

    %{destination: destination, remote: remote, writer: writer}
  end

  defp push_fixture_change!(fixture, contents) do
    commit_file!(fixture.writer, "README.md", contents, "remote update")
    git!(fixture.writer, ["push", "--quiet", "origin", "main"])
  end

  defp configure_identity!(path) do
    git!(path, ["config", "user.email", "custode@example.invalid"])
    git!(path, ["config", "user.name", "Custode Test"])
  end

  defp commit_file!(path, name, contents, message) do
    File.write!(Path.join(path, name), contents)
    git!(path, ["add", name])
    git!(path, ["commit", "--quiet", "-m", message])
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
