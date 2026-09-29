defmodule Custode.Config.WriteBackTest do
  # Config write-back (design 001 slice 2). Uses CUSTODE_CONFIG scoped to a
  # tmp path so no test touches a real roster file; env roster is saved and
  # restored around each test.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Config.{Loader, WriteBack}

  setup do
    path = Path.join(System.tmp_dir!(), uid("roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", path)
    previous_routines = Application.get_env(:custode, :routines)
    previous_sensors = Application.get_env(:custode, :sensors)
    previous_profiles = Application.get_env(:custode, :profiles)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
      Application.put_env(:custode, :routines, previous_routines)
      Application.put_env(:custode, :sensors, previous_sensors)
      Application.put_env(:custode, :profiles, previous_profiles)
    end)

    %{path: path}
  end

  defp entry(id) do
    %{
      id: id,
      profile: :backlog_worker,
      repo: "example/#{id}",
      working_dir: "/tmp/#{id}",
      tags: [:rust, :external]
    }
  end

  test "write-back then reload round-trips the entry through the real loader", %{path: path} do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "existing", cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    Application.put_env(:custode, :sensors, [])

    # CUSTODE_CONFIG points at a nonexistent path -- file_path/0 raises for
    # that, so the first write-back must not consult it before creating. Use
    # the create-then-append path by touching nothing: add_routine creates
    # the file from the LIVE roster (the existing routine) plus the append.
    assert {:ok, ^path} = WriteBack.add_routine(entry("newbie"))

    # the file now exists, carries BOTH routines, and the env was reloaded
    assert File.exists?(path)
    {:ok, ^path, routines, _sensors, _profiles} = Loader.load()
    assert Enum.map(routines, & &1.id) == ["existing", "newbie"]

    # the running roster picked it up in the same operation (no restart)
    assert Custode.Routine.get("newbie").role == :backlog_worker
    assert Custode.Routine.get("existing")

    # and the newcomer's MCP config exists NOW (found by codex_wrapper_ex's
    # first beat: boot-only config writing meant runtime adds failed every
    # turn until a restart)
    config = Custode.MCP.config_path("newbie")
    assert File.exists?(config)
    assert File.read!(config) =~ "Authorization"
  end

  test "renders the literal section a gate card would show" do
    text =
      entry("shown")
      |> Map.put(:permission_broker, :read_only)
      |> WriteBack.render_routine()

    assert text =~ ~s([[routines]])
    assert text =~ ~s(id = "shown")
    assert text =~ ~s(profile = "backlog_worker")
    assert text =~ ~s(tags = ["rust", "external"])
    assert text =~ ~s(permission_broker = "read_only")
    # and the rendered text is valid TOML the loader accepts
    {[parsed], [], _} = Loader.parse!(text)
    assert parsed.id == "shown"
    assert parsed.profile == :backlog_worker
    assert parsed.permission_broker == :read_only
  end

  test "duplicate ids and broken entries are refused as values" do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "taken", cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    assert {:error, {:duplicate_id, "taken"}} = WriteBack.add_routine(entry("taken"))
    assert {:error, :missing_id} = WriteBack.add_routine(%{profile: :backlog_worker})

    # an entry normalize rejects (no cron and no profile to supply one)
    assert {:error, {:invalid_entry, _msg}} = WriteBack.add_routine(%{id: "broken"})
  end

  test "a failed runtime preflight leaves the roster file and environment unchanged", %{
    path: path
  } do
    workspace = tmp_workspace!()
    blocked_workspace = Path.join(System.tmp_dir!(), uid("workspace-file"))
    File.write!(blocked_workspace, "not a directory")
    on_exit(fn -> File.rm(blocked_workspace) end)

    existing = %{id: "existing", cron: "@daily", workspace: workspace, prompt: "sweep"}
    Application.put_env(:custode, :routines, [existing])
    Application.put_env(:custode, :sensors, [])

    refute File.exists?(path)

    assert {:error, {:routine_preflight_failed, _reason}} =
             WriteBack.add_routine(%{
               id: "not-committed",
               cron: "@daily",
               workspace: blocked_workspace,
               prompt: "sweep"
             })

    refute File.exists?(path)
    assert [%{id: "existing"}] = Application.fetch_env!(:custode, :routines)
    assert Custode.Routine.get("not-committed") == nil
  end

  describe "update_routine/2 (#174 slice 1)" do
    setup %{path: path} do
      workspace = tmp_workspace!()

      Application.put_env(:custode, :routines, [
        %{id: "existing", cron: "@daily", workspace: workspace, prompt: "sweep"}
      ])

      Application.put_env(:custode, :sensors, [])
      {:ok, ^path} = WriteBack.add_routine(entry("newbie"))
      :ok
    end

    test "edits swap fields on the RAW entry; profile defaults stay unbaked", %{path: path} do
      assert {:ok, ^path} = WriteBack.update_routine("newbie", %{daily_budget_usd: 75.0})

      {[_existing, raw], [], _} = Loader.parse!(File.read!(path), path)
      assert raw.daily_budget_usd == 75.0
      # the assignment stayed an assignment: no profile-supplied default
      # (model, cron, prompt...) got baked into the file by the rewrite
      assert Map.keys(raw) |> Enum.sort() ==
               [:daily_budget_usd, :id, :profile, :repo, :tags, :working_dir]

      # and the live roster reloaded in the same operation
      assert Custode.Routine.get("newbie").daily_budget_usd == 75.0
    end

    test "a nil change drops the override so the profile serves again", %{path: path} do
      {:ok, ^path} = WriteBack.update_routine("newbie", %{model: "opus"})
      {[_, raw], [], _} = Loader.parse!(File.read!(path), path)
      assert raw.model == "opus"

      {:ok, ^path} = WriteBack.update_routine("newbie", %{model: nil})
      {[_, raw], [], _} = Loader.parse!(File.read!(path), path)
      refute Map.has_key?(raw, :model)
    end

    test "permission broker is editable without baking profile defaults", %{path: path} do
      assert {:ok, ^path} =
               WriteBack.update_routine("newbie", %{permission_broker: :read_only})

      {[_existing, raw], [], _} = Loader.parse!(File.read!(path), path)
      assert raw.permission_broker == :read_only
      assert File.read!(path) =~ ~s(permission_broker = "read_only")
    end

    test "changing provider stops the old engine before the next beat", %{path: path} do
      {:ok, _pid} =
        ObanClaude.Agent.start_agent("newbie",
          enqueue_fun: fn _args, _meta -> {:ok, :queued} end
        )

      on_exit(fn ->
        case ObanClaude.Agent.status("newbie") do
          {:ok, :offline} -> :ok
          {:ok, _state} -> ObanClaude.Agent.stop_agent("newbie")
        end
      end)

      assert {:ok, :idle} = ObanClaude.Agent.status("newbie")

      assert {:ok, ^path} =
               WriteBack.update_routine("newbie", %{
                 provider: :codex,
                 model: "gpt-5.6-sol"
               })

      assert {:ok, :offline} = ObanClaude.Agent.await("newbie", :offline, 1_000)
      assert Custode.Routine.get("newbie").provider == :codex
    end

    test "reload and reconciliation stay inside the admission boundary", %{path: path} do
      routine = Custode.Routine.get("newbie")
      before = routine.max_turns
      after_change = before + 1
      parent = self()
      file_before = File.read!(path)

      config =
        routine
        |> Custode.Routine.agent_config(%{})
        |> Keyword.put(:enqueue_fun, fn _args, _meta -> {:ok, :queued} end)

      {:ok, old_pid} = ObanClaude.Agent.start_agent("newbie", config)

      on_exit(fn -> stop_if_live(ObanClaude.Agent, "newbie") end)

      :ok = :sys.suspend(Custode.AgentHandoff)

      on_exit(fn ->
        case Process.whereis(Custode.AgentHandoff) do
          pid when is_pid(pid) ->
            if Process.info(pid, :status) == {:status, :suspended},
              do: :sys.resume(Custode.AgentHandoff)

          nil ->
            :ok
        end
      end)

      update =
        Task.async(fn ->
          WriteBack.update_routine("newbie", %{max_turns: after_change})
        end)

      assert Task.yield(update, 50) == nil
      assert File.read!(path) == file_before
      assert Custode.Routine.get("newbie").max_turns == before

      admission =
        Task.async(fn ->
          Custode.AgentHandoff.admit("newbie", fn ->
            {:ok, info} = Custode.Agents.info("newbie", :claude)

            send(
              parent,
              {:admitted_config, Custode.Routine.get("newbie").max_turns, info.config_revision}
            )

            :ok
          end)
        end)

      refute_receive {:admitted_config, _value, _revision}, 50
      :ok = :sys.resume(Custode.AgentHandoff)

      assert {:ok, ^path} = Task.await(update)
      assert Custode.Routine.get("newbie").max_turns == after_change
      assert File.read!(path) =~ "max_turns = #{after_change}"

      first_admission = Task.await(admission)
      assert first_admission in [:ok, {:deferred, :handoff_pending}]

      eventually(fn ->
        assert Custode.AgentHandoff.status("newbie") == :ready
        {:ok, info} = Custode.Agents.info("newbie", :claude)

        assert info.config_revision ==
                 Custode.Routine.execution_revision(Custode.Routine.get("newbie"))

        refute Process.alive?(old_pid)
      end)

      if first_admission != :ok do
        assert :ok =
                 Custode.AgentHandoff.admit("newbie", fn ->
                   {:ok, info} = Custode.Agents.info("newbie", :claude)

                   send(
                     parent,
                     {:admitted_config, Custode.Routine.get("newbie").max_turns,
                      info.config_revision}
                   )

                   :ok
                 end)
      end

      expected_revision = Custode.Routine.execution_revision(Custode.Routine.get("newbie"))
      assert_receive {:admitted_config, ^after_change, ^expected_revision}
    end

    test "concurrent disjoint edits merge against serialized roster state", %{path: path} do
      :ok = :sys.suspend(Custode.AgentHandoff)

      on_exit(fn ->
        case Process.whereis(Custode.AgentHandoff) do
          pid when is_pid(pid) ->
            if Process.info(pid, :status) == {:status, :suspended},
              do: :sys.resume(Custode.AgentHandoff)

          nil ->
            :ok
        end
      end)

      budget = Task.async(fn -> WriteBack.update_routine("newbie", %{max_budget_usd: 3.0}) end)
      turns = Task.async(fn -> WriteBack.update_routine("newbie", %{max_turns: 41}) end)

      assert Task.yield(budget, 50) == nil
      assert Task.yield(turns, 50) == nil
      :ok = :sys.resume(Custode.AgentHandoff)

      assert {:ok, ^path} = Task.await(budget)
      assert {:ok, ^path} = Task.await(turns)

      {[_, raw], [], _profiles} = Loader.parse!(File.read!(path), path)
      assert raw.max_budget_usd == 3.0
      assert raw.max_turns == 41
    end

    test "the splice preserves other entries byte-for-byte, comments included", %{path: path} do
      # an operator hand-comment above the OTHER entry's section
      content = File.read!(path)

      commented =
        String.replace(
          content,
          "[[routines]]\nid = \"existing\"",
          "# hands off: pinned by the operator\n[[routines]]\nid = \"existing\"",
          global: false
        )

      File.write!(path, commented)

      {:ok, ^path} = WriteBack.update_routine("newbie", %{max_turns: 99})
      after_edit = File.read!(path)
      assert after_edit =~ "# hands off: pinned by the operator"
      {[_, raw], [], _} = Loader.parse!(after_edit, path)
      assert raw.max_turns == 99
    end

    test "unknown ids, id changes, unknown keys, and broken merges are refused" do
      assert {:error, {:unknown_id, "ghost"}} =
               WriteBack.update_routine("ghost", %{model: "opus"})

      assert {:error, :id_is_immutable} = WriteBack.update_routine("newbie", %{id: "renamed"})

      assert {:error, {:unknown_keys, [:budget]}} =
               WriteBack.update_routine("newbie", %{budget: 1})

      assert {:error, :empty_changes} = WriteBack.update_routine("newbie", %{})

      # dropping the profile leaves an entry with no cron: normalize refuses
      assert {:error, {:invalid_entry, _msg}} =
               WriteBack.update_routine("newbie", %{profile: nil})
    end

    test "remove_routine splices the section out and the roster forgets it", %{path: path} do
      assert {:ok, ^path} = WriteBack.remove_routine("newbie")

      {[only], [], _} = Loader.parse!(File.read!(path), path)
      assert only.id == "existing"
      assert Custode.Routine.get("newbie") == nil
      assert Custode.Routine.get("existing")

      assert {:error, {:unknown_id, "newbie"}} = WriteBack.remove_routine("newbie")
    end

    test "remove_routine refuses split live ownership before rewriting the roster", %{path: path} do
      id = uid("split-owner")

      assert {:ok, ^path} =
               WriteBack.add_routine(%{
                 id: id,
                 profile: :backlog_worker,
                 workspace: tmp_workspace!()
               })

      on_exit(fn ->
        stop_if_live(ObanClaude.Agent, id)
        stop_if_live(ObanCodex.Agent, id)
      end)

      {:ok, _claude} =
        ObanClaude.Agent.start_agent(id,
          enqueue_fun: fn _args, _meta -> {:ok, :queued} end
        )

      {:ok, _codex} =
        ObanCodex.Agent.start_agent(id,
          enqueue_fun: fn _args, _meta -> {:ok, :queued} end
        )

      assert {:error,
              {:reconfigure_failed_reconcile_pending,
               {:remove_live_agent_failed, ^id, :multiple_live_providers},
               [{^id, :multiple_live_providers}]}} = WriteBack.remove_routine(id)

      assert Custode.Routine.get(id)
      assert File.read!(path) =~ ~s(id = "#{id}")
      assert {:ok, :idle} = ObanClaude.Agent.status(id)
      assert {:ok, :idle} = ObanCodex.Agent.status(id)
    end
  end

  test "a runtime add serves its repo immediately; removal retires an orphaned server (#221)",
       %{path: path} do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "existing", cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    Application.put_env(:custode, :sensors, [])
    repo = "acme/" <> uid("served")
    refute Custode.Repository.served?(repo)

    {:ok, ^path} =
      WriteBack.add_routine(%{
        id: "server-check",
        profile: :backlog_worker,
        repo: repo,
        working_dir: "/tmp/x"
      })

    # the newcomer's repo_* verbs would pass the served? gate right now
    assert Custode.Repository.served?(repo)

    {:ok, ^path} = WriteBack.remove_routine("server-check")
    refute Custode.Repository.served?(repo)
  end

  test "an edit in exs mode creates the file: the design 001 mode switch", %{path: path} do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "solo", cron: "@daily", workspace: workspace, prompt: "sweep", max_turns: 10}
    ])

    Application.put_env(:custode, :sensors, [])
    refute File.exists?(path)

    assert {:ok, ^path} = WriteBack.update_routine("solo", %{max_turns: 20})

    # the file was born from the whole live roster with the edit applied
    assert File.exists?(path)
    {[raw], [], _} = Loader.parse!(File.read!(path), path)
    assert raw.id == "solo"
    assert raw.max_turns == 20
  end

  # --- profiles (#236) ---

  defp seed_profiles(path) do
    Application.put_env(:custode, :routines, [])
    Application.put_env(:custode, :sensors, [])

    Application.put_env(:custode, :profiles, %{
      tutor: %{cron: "@daily", role: :tutor, model: "sonnet", max_turns: 15}
    })

    refute File.exists?(path)
  end

  defp new_envelope do
    %{
      cron: "@daily",
      prompt: "do your sweep",
      role: :backlog_worker,
      model: "sonnet",
      tags: [:repo],
      sensors: [:ci],
      extra_allowed_tools: ["Bash(git log:*)"],
      approved_args: %{"permission_mode" => "bypass_permissions", "model" => "opus"}
    }
  end

  test "add_profile round-trips a new profile through the real loader", %{path: path} do
    seed_profiles(path)

    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    # the file exists, carries BOTH profiles, and the env reloaded (D1)
    {:ok, ^path, _routines, _sensors, profiles} = Loader.load()
    assert Map.has_key?(profiles, :tutor)
    assert profiles.reviewer.role == :backlog_worker
    assert profiles.reviewer.sensors == [:ci]
    assert profiles.reviewer.approved_args["permission_mode"] == "bypass_permissions"

    # a routine can inherit it right now, no restart
    assert Application.get_env(:custode, :profiles).reviewer.model == "sonnet"
  end

  test "add_profile refuses a duplicate name", %{path: path} do
    seed_profiles(path)
    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    assert {:error, {:duplicate_profile, "reviewer"}} =
             WriteBack.add_profile("reviewer", new_envelope())
  end

  test "add_profile refuses an unknown envelope key", %{path: path} do
    seed_profiles(path)
    assert {:error, {:unknown_keys, [:bogus]}} = WriteBack.add_profile("x", %{bogus: 1})
  end

  test "update_profile merges changes and drops nil keys", %{path: path} do
    seed_profiles(path)
    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    assert {:ok, ^path} =
             WriteBack.update_profile("reviewer", %{model: "opus", extra_allowed_tools: nil})

    {:ok, ^path, _routines, _sensors, profiles} = Loader.load()
    assert profiles.reviewer.model == "opus"
    refute Map.has_key?(profiles.reviewer, :extra_allowed_tools)
    # the other profile survives the splice byte-for-byte
    assert profiles.tutor.role == :tutor
  end

  test "update_profile refuses an envelope that would invalidate a wearer", %{path: path} do
    seed_profiles(path)
    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    assert {:ok, ^path} =
             WriteBack.add_routine(%{
               id: "profile-wearer",
               profile: :reviewer,
               workspace: tmp_workspace!()
             })

    before = File.read!(path)
    before_profiles = Application.fetch_env!(:custode, :profiles)

    assert {:error, {:invalid_profile_wearer, "profile-wearer", _reason}} =
             WriteBack.update_profile("reviewer", %{provider: :codex})

    assert File.read!(path) == before
    assert Application.fetch_env!(:custode, :profiles) == before_profiles
    assert Process.alive?(Process.whereis(Custode.AgentHandoff))
  end

  test "changing a profile provider stops live wearers on the old engine", %{path: path} do
    seed_profiles(path)
    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    assert {:ok, ^path} =
             WriteBack.add_routine(%{
               id: "profile-wearer",
               profile: :reviewer,
               workspace: tmp_workspace!()
             })

    {:ok, _pid} =
      ObanClaude.Agent.start_agent("profile-wearer",
        enqueue_fun: fn _args, _meta -> {:ok, :queued} end
      )

    on_exit(fn ->
      case ObanClaude.Agent.status("profile-wearer") do
        {:ok, :offline} -> :ok
        {:ok, _state} -> ObanClaude.Agent.stop_agent("profile-wearer")
      end
    end)

    assert {:ok, ^path} =
             WriteBack.update_profile("reviewer", %{
               provider: :codex,
               model: nil,
               approved_args: nil
             })

    assert {:ok, :offline} = ObanClaude.Agent.await("profile-wearer", :offline, 1_000)
    assert Custode.Routine.get("profile-wearer").provider == :codex
  end

  test "remove_profile refuses while a routine wears it, allows once orphaned", %{path: path} do
    seed_profiles(path)
    assert {:ok, ^path} = WriteBack.add_profile("reviewer", new_envelope())

    workspace = tmp_workspace!()

    assert {:ok, ^path} =
             WriteBack.add_routine(%{
               id: "wearer",
               profile: :reviewer,
               workspace: workspace,
               repo: "example/wearer",
               working_dir: "/tmp/wearer"
             })

    assert {:error, {:profile_in_use, ["wearer"]}} = WriteBack.remove_profile("reviewer")

    {:ok, ^path} = WriteBack.remove_routine("wearer")
    assert {:ok, ^path} = WriteBack.remove_profile("reviewer")

    {:ok, ^path, _routines, _sensors, profiles} = Loader.load()
    refute Map.has_key?(profiles, :reviewer)
  end

  test "preview_profile surfaces the dangerous grants for the gate card" do
    {:ok, %{toml: toml, grants: grants}} =
      WriteBack.preview_new_profile("reviewer", new_envelope())

    assert toml =~ ~s([[profiles]])
    assert toml =~ ~s(name = "reviewer")
    assert toml =~ ~s([profiles.approved_args])

    assert "approved_args grants bypass_permissions" in grants
    assert "role: backlog_worker" in grants
    assert Enum.any?(grants, &String.contains?(&1, "extra_allowed_tools"))
  end

  defp stop_if_live(module, id) do
    case module.status(id) do
      {:ok, :offline} -> :ok
      {:ok, _state} -> module.stop_agent(id)
    end
  end
end
