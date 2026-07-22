defmodule Custode.RosterToolsTest do
  # The roster mutation tools (#75 / design 001 slice 3): preview renders the
  # literal TOML for gate cards; add_routine writes file + live roster in one
  # operation, guarded by caller identity and the external-is-human-only
  # policy. Handlers called directly with frames, per the house pattern.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.RosterTools.{AddRoutine, PreviewRoutine}

  @operator %Anubis.Server.Frame{}

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  defp sub_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :sub_agent, id: id}}}

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

    assert refused =~ "only the caretaker provisions"
    assert Custode.Routine.get("workeradd") == nil

    refused = tool_error(AddRoutine.execute(%{id: "subadd"}, sub_frame("helper")))
    assert refused =~ "sub-agents do not provision"
  end

  test "an :external routine adds through the caretaker's gate flow and the operator alike" do
    # the caretaker's add only runs as an approved continuation, so the human
    # read the rendered TOML -- that approval is the :external protection now
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

    assert refused =~ "only the caretaker provisions"
  end

  test "duplicates and unknown profiles come back as tool errors" do
    refused = tool_error(AddRoutine.execute(%{id: "existing"}, @operator))
    assert refused =~ "duplicate_id"

    refused = tool_error(AddRoutine.execute(%{id: "x", profile: "bogus_profile"}, @operator))
    assert refused =~ "unknown profile"
  end
end
