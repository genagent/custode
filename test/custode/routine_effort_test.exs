defmodule Custode.RoutineEffortTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{Agents, Repo, Routine}
  alias Custode.CLI.Client
  alias Custode.Config.{Loader, WriteBack}
  alias Custode.MCP.Identity
  alias Custode.Operator.RoutineEdit

  setup do
    workspace = tmp_workspace!()
    path = Path.join(workspace, "routines.toml")
    profile = %{cron: :manual, prompt: "Check the assignment.", effort: "low"}
    File.write!(path, WriteBack.render_profile("effort_test", profile))

    for {key, value} <- [
          {"CUSTODE_CONFIG", path},
          {"CUSTODE_MCP_PORT", to_string(Custode.MCP.port())},
          {"CUSTODE_OPERATOR_TOKEN", File.read!(Identity.operator_token_path())}
        ] do
      previous = System.get_env(key)
      System.put_env(key, value)

      on_exit(fn ->
        if previous, do: System.put_env(key, previous), else: System.delete_env(key)
      end)
    end

    put_env!(:routines, [])
    put_env!(:sensors, [])
    put_env!(:profiles, %{effort_test: profile})
    put_env!(:feed_path, Path.join(workspace, "feed.jsonl"))

    id = uid("effort")

    on_exit(fn ->
      File.rm(Custode.MCP.config_path(id))
    end)

    %{id: id, path: path, workspace: workspace}
  end

  test "string and atom efforts from Elixir config build the same actual tick args", context do
    for effort <- [:low, :medium, :high, :xhigh, :max], value <- [effort, to_string(effort)] do
      routine = context |> entry() |> Map.put(:effort, value) |> Routine.normalize_entry()
      assert routine.effort == effort
      assert Routine.tick_args(routine)["start"]["args"]["effort"] == to_string(effort)
    end

    routine = context |> entry() |> Map.delete(:profile) |> Routine.normalize_entry()
    assert routine.effort == nil
    refute Map.has_key?(Routine.tick_args(routine)["start"]["args"], "effort")
  end

  test "TOML routine overrides and profile defaults both dispatch", context do
    toml =
      File.read!(context.path) <>
        WriteBack.render_routine(entry(context)) <>
        WriteBack.render_routine(
          %{entry(context) | id: uid("override")}
          |> Map.put(:effort, :high)
        )

    {routines, _sensors, profiles} = Loader.parse!(toml)
    put_env!(:routines, routines)
    put_env!(:profiles, profiles)

    assert Enum.map(Routine.all(), &Routine.tick_args(&1)["start"]["args"]["effort"]) == [
             "low",
             "high"
           ]
  end

  test "MCP add with explicit effort can immediately prompt an offline routine", context do
    assert {:ok, %{"live" => true}} =
             Client.call("add_routine", Map.put(arguments(context), :effort, "high"))

    assert {:ok, %{"delivered" => true, "how" => "started"}} =
             Client.call("prompt_agent", %{
               agent_id: context.id,
               prompt: "Diagnose the failing test."
             })

    on_exit(fn -> Agents.stop_agent(context.id) end)

    assert [job] =
             Repo.all(from(j in Oban.Job, where: j.worker == "ObanClaude.Agent.Job"))
             |> Enum.filter(&(&1.meta["agent_id"] == context.id))

    on_exit(fn -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)
    assert job.args["prompt"] == "Diagnose the failing test."
    assert job.args["effort"] == "high"
    assert job.meta["arc_id"] =~ "operator:"
    assert job.state == "available"
  end

  test "MCP updates and dropping an override preserve profile inheritance", context do
    assert {:ok, _} = Client.call("add_routine", arguments(context))
    assert {:ok, _} = Client.call("update_routine", %{id: context.id, effort: "max"})
    assert tick_effort(context.id) == "max"

    assert {:ok, _} = Client.call("update_routine", %{id: context.id, drop: ["effort"]})
    assert tick_effort(context.id) == "low"
  end

  test "MCP-defined and updated profile effort is inherited by actual tick args", context do
    name = uid("effort-profile")

    assert {:ok, _} =
             Client.call("define_profile", %{
               name: name,
               cron: "manual",
               prompt: "Check the assignment.",
               effort: "xhigh"
             })

    assert {:ok, _} = Client.call("add_routine", %{arguments(context) | profile: name})
    assert tick_effort(context.id) == "xhigh"
    assert {:ok, _} = Client.call("update_profile", %{name: name, effort: "medium"})
    assert tick_effort(context.id) == "medium"
  end

  test "form edits save an effort that dispatches, and blank restores inheritance", context do
    assert {:ok, _} = WriteBack.add_routine(entry(context))
    assert {:ok, original} = RoutineEdit.load(context.id)

    assert {:ok, :saved} =
             RoutineEdit.save(context.id, original, Map.put(original, "effort", " high "))

    assert tick_effort(context.id) == "high"
    assert {:ok, changed} = RoutineEdit.load(context.id)
    assert changed["effort"] == "high"
    assert {:ok, :saved} = RoutineEdit.save(context.id, changed, Map.put(changed, "effort", ""))
    assert tick_effort(context.id) == "low"
  end

  test "TOML rejects unsupported effort without creating an atom", context do
    unknown = uid("unknown-effort")

    for invalid <- ["running", unknown] do
      for toml <- [
            WriteBack.render_routine(Map.put(entry(context), :effort, invalid)),
            WriteBack.render_profile("invalid", %{effort: invalid})
          ] do
        assert_raise ArgumentError, ~r/unknown effort/, fn -> Loader.parse!(toml) end
      end
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "invalid routine and profile efforts are refused before any write", context do
    before = File.read!(context.path)

    for invalid <- [:running, "running", true, 5] do
      assert {:error, {:invalid_entry, message}} =
               WriteBack.add_routine(Map.put(entry(context), :effort, invalid))

      assert message =~ "unknown effort"

      assert {:error, {:invalid_profile, message}} =
               WriteBack.add_profile("invalid-effort", %{effort: invalid})

      assert message =~ "unknown effort"
      assert File.read!(context.path) == before
    end
  end

  test "MCP previews and writes return useful errors for invalid effort", context do
    before = File.read!(context.path)

    for tool <- ["preview_routine", "add_routine"] do
      assert {:error, message} =
               Client.call(tool, Map.put(arguments(context), :effort, "running"))

      assert message =~ "unknown effort"
    end

    for tool <- ["preview_profile", "define_profile"] do
      assert {:error, message} = Client.call(tool, %{name: "invalid-effort", effort: "running"})
      assert message =~ "unknown effort"
    end

    assert File.read!(context.path) == before
  end

  test "invalid edits leave the saved routine and inherited profile usable", context do
    assert {:ok, _} = WriteBack.add_routine(entry(context))
    before = File.read!(context.path)

    for {tool, params} <- [
          {"update_routine", %{id: context.id, effort: "running"}},
          {"update_profile", %{name: "effort_test", effort: "running"}}
        ] do
      assert {:error, message} = Client.call(tool, params)
      assert message =~ "unknown effort"
    end

    assert {:ok, original} = RoutineEdit.load(context.id)

    assert {:error, message} =
             RoutineEdit.save(context.id, original, Map.put(original, "effort", "running"))

    assert message =~ "unknown effort"
    assert File.read!(context.path) == before
    assert tick_effort(context.id) == "low"
  end

  defp entry(context) do
    %{
      id: context.id,
      profile: :effort_test,
      cron: :manual,
      prompt: "Check the assignment.",
      workspace: context.workspace,
      working_dir: context.workspace
    }
  end

  defp arguments(context),
    do: %{id: context.id, profile: "effort_test", workspace: context.workspace}

  defp tick_effort(id),
    do: Routine.get(id) |> Routine.tick_args() |> get_in(["start", "args", "effort"])
end
