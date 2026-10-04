defmodule Custode.RosterToolsTest do
  # The roster mutation tools (#75 / design 001 slice 3): preview renders the
  # literal TOML for gate cards; add_routine writes file + live roster in one
  # operation, guarded by caller identity and the external-is-human-only
  # policy. Handlers called directly with frames, per the house pattern.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Gates.Gate
  alias Custode.MCP.RosterTools.{AddRoutine, PreviewRoutine}
  alias Custode.Repo

  @operator %Custode.MCP.CallContext{}

  defp routine_frame(id),
    do: %Custode.MCP.CallContext{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  defp sub_frame(id),
    do: %Custode.MCP.CallContext{assigns: %{custode_identity: %{kind: :sub_agent, id: id}}}

  defp grant_roster!(id, class \\ "roster") do
    gate =
      Repo.insert!(%Gate{
        agent_id: id,
        kind: "approval",
        action_id: uid("roster-action"),
        class: class,
        status: "resolved",
        outcome: "approved"
      })

    on_exit(fn -> Repo.delete(gate) end)
    gate
  end

  setup do
    path = Path.join(System.tmp_dir!(), uid("roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", path)
    previous = Application.get_env(:custode, :routines)
    feed = Path.join(System.tmp_dir!(), uid("roster-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
      File.rm(feed)
      Application.put_env(:custode, :routines, previous)
    end)

    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      # role matters here: normalize defaults role to :caretaker, and the
      # write guard keys on exactly that
      %{
        id: "existing",
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep",
        role: :star_tracker
      },
      %{
        id: "keeper",
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep",
        role: :caretaker
      }
    ])

    %{path: path}
  end

  test "preview renders the literal section without touching anything", %{path: path} do
    json =
      tool_json(
        PreviewRoutine.execute(
          %{id: "newbie", profile: "backlog_worker", repo: "o/r", tags: ["rust"]},
          routine_frame("anyone")
        )
      )

    assert json["toml"] =~ ~s([[routines]])
    assert json["toml"] =~ ~s(id = "newbie")
    assert json["toml"] =~ ~s(profile = "backlog_worker")
    refute File.exists?(path)
  end

  test "provider is exposed by preview and add", %{path: path} do
    json = tool_json(PreviewRoutine.execute(%{id: "codex-preview", provider: "codex"}, @operator))
    assert json["toml"] =~ ~s(provider = "codex")

    json =
      tool_json(
        AddRoutine.execute(
          %{id: "codex-add", provider: "codex", profile: "backlog_worker", repo: "o/codex"},
          @operator
        )
      )

    assert json["live"] == true
    routine = Custode.Routine.get("codex-add")
    assert routine.provider == :codex
    assert routine.model == Application.get_env(:custode, :codex_model)

    assert routine.approved_args == %{
             "sandbox" => "workspace_write",
             "approval_policy" => "never"
           }

    assert File.read!(path) =~ ~s(provider = "codex")
  end

  test "the operator adds a routine: file written, roster live", %{path: path} do
    json =
      tool_json(
        AddRoutine.execute(
          %{id: "opadd", profile: "backlog_worker", repo: "o/r", working_dir: "/tmp/o"},
          @operator
        )
      )

    assert json["live"] == true
    assert File.exists?(path)
    assert Custode.Routine.get("opadd").role == :backlog_worker
  end

  test "the caretaker's continuation may add; other routines may not" do
    refused =
      tool_error(
        AddRoutine.execute(
          %{id: "ungated", profile: "backlog_worker", repo: "o/r"},
          routine_frame("keeper")
        )
      )

    assert refused =~ "active human-approved roster continuation"
    assert Custode.Routine.get("ungated") == nil

    grant_roster!("keeper", "merge")

    refused =
      tool_error(
        AddRoutine.execute(
          %{id: "wrong-grant", profile: "backlog_worker", repo: "o/r"},
          routine_frame("keeper")
        )
      )

    assert refused =~ "active human-approved roster continuation"
    assert Custode.Routine.get("wrong-grant") == nil

    grant_roster!("keeper")

    json =
      tool_json(
        AddRoutine.execute(
          %{id: "caretakeradd", profile: "backlog_worker", repo: "o/r"},
          routine_frame("keeper")
        )
      )

    assert json["live"] == true

    refused =
      tool_error(
        AddRoutine.execute(
          %{id: "workeradd", profile: "backlog_worker"},
          routine_frame("existing")
        )
      )

    assert refused =~ "human operator or caretaker role"
    assert Custode.Routine.get("workeradd") == nil

    refused = tool_error(AddRoutine.execute(%{id: "subadd"}, sub_frame("helper")))
    assert refused =~ "temporary agents may not write"
  end

  test "an :external routine adds through the caretaker's gate flow and the operator alike" do
    # the caretaker's add only runs as an approved continuation, so the human
    # read the rendered TOML -- that approval is the :external protection now
    grant_roster!("keeper")

    json =
      tool_json(
        AddRoutine.execute(
          %{id: "extadd", profile: "backlog_worker", repo: "o/r", tags: ["rust", "external"]},
          routine_frame("keeper")
        )
      )

    assert json["live"] == true

    # a WORKER still cannot add anything, external or not
    refused =
      tool_error(
        AddRoutine.execute(
          %{id: "extadd2", profile: "backlog_worker", tags: ["rust", "external"]},
          routine_frame("existing")
        )
      )

    assert refused =~ "human operator or caretaker role"
  end

  test "duplicates and unknown profiles come back as tool errors" do
    refused = tool_error(AddRoutine.execute(%{id: "existing"}, @operator))
    assert refused =~ "duplicate_id"

    refused = tool_error(AddRoutine.execute(%{id: "x", profile: "bogus_profile"}, @operator))
    assert refused =~ "unknown profile"
  end

  describe "the edit verbs (#174 slice 3)" do
    alias Custode.MCP.RosterTools.{PreviewRoutineEdit, RemoveRoutine, UpdateRoutine}

    test "preview_routine_edit renders before and after without writing", %{path: path} do
      json =
        tool_json(
          PreviewRoutineEdit.execute(
            %{id: "existing", daily_budget_usd: 75.0},
            routine_frame("anyone")
          )
        )

      assert json["before"] =~ ~s(id = "existing")
      refute json["before"] =~ "daily_budget_usd"
      assert json["after"] =~ ~s(daily_budget_usd = 75.0)
      refute File.exists?(path)
    end

    test "the caretaker edits through the gate flow; a worker is refused", %{path: path} do
      grant_roster!("keeper")

      json =
        tool_json(
          UpdateRoutine.execute(
            %{id: "existing", daily_budget_usd: 75.0},
            routine_frame("keeper")
          )
        )

      assert json["live"] == true
      assert File.read!(path) =~ ~s(daily_budget_usd = 75.0)

      refused =
        tool_error(
          UpdateRoutine.execute(%{id: "keeper", model: "opus"}, routine_frame("existing"))
        )

      assert refused =~ "human operator or caretaker role"
    end

    test "drop removes an override so the profile serves again" do
      tool_json(UpdateRoutine.execute(%{id: "existing", model: "opus"}, @operator))
      assert Custode.Routine.get("existing").model == "opus"

      # asserted on the live routine, not the file text: the file now also
      # carries the [[profiles]] dump (#236), whose backlog_worker profile
      # has its own model = "opus" line
      tool_json(UpdateRoutine.execute(%{id: "existing", drop: ["model"]}, @operator))
      refute Custode.Routine.get("existing").model == "opus"
    end

    test "the whole roster vocabulary is editable through the verbs (operator ask, 2026-07-22)" do
      # every loader key except the deliberate exclusions is one edit away
      json =
        tool_json(
          UpdateRoutine.execute(
            %{
              id: "existing",
              mcp: true,
              hermetic: true,
              daily_budget_tokens: 500_000,
              extra_allowed_tools: ["Bash(git log:*)"]
            },
            @operator
          )
        )

      assert json["live"] == true
      routine = Custode.Routine.get("existing")
      assert routine.hermetic == true
      assert routine.daily_budget_tokens == 500_000
      assert "Bash(git log:*)" in routine.extra_allowed_tools

      # the add vocabulary matches: a fully-specified newcomer in one call
      json =
        tool_json(
          AddRoutine.execute(
            %{
              id: "fullspec",
              profile: "backlog_worker",
              repo: "o/full",
              model: "haiku",
              max_budget_usd: 0.25,
              max_turns: 10
            },
            @operator
          )
        )

      assert json["live"] == true
      full = Custode.Routine.get("fullspec")
      assert full.model == "haiku"
      assert full.max_turns == 10
    end

    test "remove_routine splices the entry out; unknown ids and workers are refused", %{
      path: path
    } do
      grant_roster!("keeper")
      json = tool_json(RemoveRoutine.execute(%{id: "existing"}, routine_frame("keeper")))
      assert json["live"] == true
      refute File.read!(path) =~ ~s(id = "existing")
      assert Custode.Routine.get("existing") == nil

      refused = tool_error(RemoveRoutine.execute(%{id: "ghost"}, @operator))
      assert refused =~ "unknown_id"

      refused = tool_error(RemoveRoutine.execute(%{id: "keeper"}, routine_frame("nobody")))
      assert refused =~ "human operator or caretaker role"
    end
  end
end
