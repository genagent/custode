defmodule Custode.SubAgentsTest do
  # Sub-agent revival (#5): record at spawn, session kept fresh by telemetry,
  # boot reconcile turns rows into parent-inbox orphan notices. Rows are
  # scoped by unique agent ids; each test cleans up its own.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.SubAgents

  setup do
    path = Path.join(System.tmp_dir!(), uid("subagents-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "spawn records the spec; a completed turn freshens the session id" do
    id = uid("sub")
    parent = uid("parent")

    :ok = SubAgents.record_spawn!(id, parent, %{workspace: "/tmp/w", model: "haiku"})

    row = Enum.find(SubAgents.all(), &(&1.agent_id == id))
    assert row.parent == parent
    assert row.session_id == nil

    # a real run through the telemetry path carries the session home
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "work"},
        job: %Oban.Job{meta: %{"agent_id" => id, "origin" => "tick"}},
        query_fun:
          ObanClaude.Testing.respond(
            ObanClaude.Testing.result(result: "done", session_id: "sess-revive-1")
          )
      )

    row = Enum.find(SubAgents.all(), &(&1.agent_id == id))
    assert row.session_id == "sess-revive-1"
    assert row.last_turn_at != nil
  after
    for row <- SubAgents.all(), do: SubAgents.forget(row.agent_id)
  end

  test "reconcile turns each row into a parent orphan notice with the revival handle" do
    parent = uid("parent")
    workspace = tmp_workspace!()
    put_env!(:routines, [%{id: parent, cron: :manual, workspace: workspace, prompt: "x"}])

    id = uid("sub")
    :ok = SubAgents.record_spawn!(id, parent, %{workspace: "/tmp/deep", model: "haiku"})

    assert SubAgents.reconcile!() >= 1

    # the notice landed in the PARENT's inbox with the handle
    [note_path] = Path.wildcard(Path.join([workspace, "inbox", "orphan-#{id}-*"]))
    note = File.read!(note_path)
    assert note =~ "Orphaned sub-agent: #{id}"
    assert note =~ "workspace: `/tmp/deep`"
    assert note =~ "nothing revives automatically"

    # rows are gone: the notice is the record now, and a second reconcile
    # will not re-nag this orphan
    refute Enum.any?(SubAgents.all(), &(&1.agent_id == id))
  end

  test "forget removes an ended sub-agent's spec" do
    id = uid("sub")
    :ok = SubAgents.record_spawn!(id, uid("parent"), %{workspace: "/tmp/w"})
    SubAgents.forget(id)
    refute Enum.any?(SubAgents.all(), &(&1.agent_id == id))
  end
end
