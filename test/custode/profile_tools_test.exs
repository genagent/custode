defmodule Custode.ProfileToolsTest do
  # The profile mutation tools (#236): preview renders the literal [[profiles]]
  # TOML plus the dangerous grants for the gate card; define/update/remove
  # write file + live roster in one operation, guarded by caller identity
  # (caretaker-only, the same single-writer gate the roster uses). Handlers
  # called directly with frames, per the house pattern.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Config.WriteBack

  alias Custode.MCP.ProfileTools.{
    DefineProfile,
    PreviewProfile,
    PreviewProfileEdit,
    RemoveProfile,
    UpdateProfile
  }

  @operator %Anubis.Server.Frame{}

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  defp sub_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :sub_agent, id: id}}}

  setup do
    path = Path.join(System.tmp_dir!(), uid("roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", path)
    prev_routines = Application.get_env(:custode, :routines)
    prev_profiles = Application.get_env(:custode, :profiles)
    feed = Path.join(System.tmp_dir!(), uid("profile-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
      File.rm(feed)
      Application.put_env(:custode, :routines, prev_routines)
      Application.put_env(:custode, :profiles, prev_profiles)
    end)

    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "worker", cron: "@daily", workspace: workspace, prompt: "sweep", role: :star_tracker},
      %{id: "keeper", cron: "@daily", workspace: workspace, prompt: "sweep", role: :caretaker}
    ])

    Application.put_env(:custode, :profiles, %{
      tutor: %{cron: "@daily", role: :tutor, model: "sonnet", max_turns: 15}
    })

    %{path: path}
  end

  defp define_params(name) do
    %{
      name: name,
      cron: "@daily",
      prompt: "do your sweep",
      role: "backlog_worker",
      model: "sonnet",
      tags: ["repo"],
      sensors: ["ci"],
      extra_allowed_tools: ["Bash(git log:*)"],
      approve_bypass_permissions: true,
      approve_model: "opus"
    }
  end

  test "preview_profile renders the section and flags the grants, no write", %{path: path} do
    json = tool_json(PreviewProfile.execute(define_params("reviewer"), routine_frame("anyone")))

    assert json["toml"] =~ ~s([[profiles]])
    assert json["toml"] =~ ~s(name = "reviewer")
    assert json["toml"] =~ ~s([profiles.approved_args])
    assert "approved_args grants bypass_permissions" in json["grants"]
    assert "role: backlog_worker" in json["grants"]
    refute File.exists?(path)
  end

  test "the operator defines a profile: file written, roster live", %{path: path} do
    json = tool_json(DefineProfile.execute(define_params("reviewer"), @operator))

    assert json["live"] == true
    assert File.exists?(path)
    profiles = Application.get_env(:custode, :profiles)
    assert profiles.reviewer.role == :backlog_worker
    assert profiles.reviewer.approved_args["permission_mode"] == "bypass_permissions"
    # the pre-existing profile survives the write
    assert profiles.tutor.role == :tutor
  end

  test "the caretaker's continuation may define; other routines and sub-agents may not" do
    json = tool_json(DefineProfile.execute(define_params("cared"), routine_frame("keeper")))
    assert json["live"] == true

    refused = tool_error(DefineProfile.execute(define_params("worked"), routine_frame("worker")))
    assert refused =~ "only the caretaker writes the roster"
    refute Map.has_key?(Application.get_env(:custode, :profiles), :worked)

    refused = tool_error(DefineProfile.execute(define_params("subbed"), sub_frame("helper")))
    assert refused =~ "sub-agents do not touch the roster"
  end

  test "define refuses a duplicate name", %{path: _path} do
    tool_json(DefineProfile.execute(define_params("reviewer"), @operator))
    refused = tool_error(DefineProfile.execute(define_params("reviewer"), @operator))
    assert refused =~ "duplicate_profile"
  end

  test "preview_profile_edit renders before/after and grants without writing", %{path: path} do
    tool_json(DefineProfile.execute(define_params("reviewer"), @operator))

    json =
      tool_json(
        PreviewProfileEdit.execute(%{name: "reviewer", model: "opus"}, routine_frame("anyone"))
      )

    assert json["before"] =~ ~s(model = "sonnet")
    assert json["after"] =~ ~s(model = "opus")
    assert "approved_args grants bypass_permissions" in json["grants"]
    # the file only holds what the earlier define wrote, unchanged
    assert File.read!(path) =~ ~s(model = "sonnet")
  end

  test "the caretaker updates a profile; a worker is refused", %{path: path} do
    tool_json(DefineProfile.execute(define_params("reviewer"), @operator))

    json =
      tool_json(
        UpdateProfile.execute(%{name: "reviewer", model: "opus"}, routine_frame("keeper"))
      )

    assert json["live"] == true
    assert File.read!(path) =~ ~s(model = "opus")

    refused =
      tool_error(
        UpdateProfile.execute(%{name: "reviewer", model: "haiku"}, routine_frame("worker"))
      )

    assert refused =~ "only the caretaker writes the roster"
  end

  test "drop removes an envelope key so nothing overrides it", %{path: _path} do
    tool_json(DefineProfile.execute(define_params("reviewer"), @operator))
    assert Application.get_env(:custode, :profiles).reviewer.model == "sonnet"

    tool_json(UpdateProfile.execute(%{name: "reviewer", drop: ["model"]}, @operator))
    refute Map.has_key?(Application.get_env(:custode, :profiles).reviewer, :model)
  end

  test "remove_profile refuses while worn, succeeds once orphaned", %{path: _path} do
    tool_json(DefineProfile.execute(define_params("reviewer"), @operator))

    # add a routine that wears it (through the write-back so the roster is live)
    workspace = tmp_workspace!()

    {:ok, _} =
      WriteBack.add_routine(%{
        id: "wearer",
        profile: :reviewer,
        workspace: workspace,
        repo: "o/wearer",
        working_dir: "/tmp/wearer"
      })

    refused = tool_error(RemoveProfile.execute(%{name: "reviewer"}, @operator))
    assert refused =~ "profile_in_use"

    {:ok, _} = WriteBack.remove_routine("wearer")
    json = tool_json(RemoveProfile.execute(%{name: "reviewer"}, @operator))
    assert json["live"] == true
    refute Map.has_key?(Application.get_env(:custode, :profiles), :reviewer)
  end
end
