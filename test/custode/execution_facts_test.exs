defmodule Custode.ExecutionFactsTest do
  use ExUnit.Case, async: true

  alias Custode.ExecutionFacts

  @desired %{
    provider: "codex",
    model: "gpt-5.6-sol",
    effort: "high",
    working_dir: "/tmp/desired",
    config_revision: "desired-revision"
  }

  @captured %{
    id: 41,
    state: "executing",
    provider: "claude",
    model: "haiku",
    effort: "low",
    working_dir: "/tmp/captured",
    config_revision: "job-revision",
    generation: "generation-1",
    turn_id: "turn-1"
  }

  test "a changed desired contract never relabels the applied process or captured turn" do
    process = process(:running, "applied-revision")

    facts = ExecutionFacts.project(@desired, process, [@captured])

    assert facts.active ==
             @captured
             |> Map.put(:lifecycle_state, "running")
             |> Map.put(:process_revision, "applied-revision")
             |> Map.put(:revision_mismatch, true)

    assert facts.applied == %{
             provider: "claude",
             model: nil,
             effort: nil,
             working_dir: nil,
             config_revision: "applied-revision",
             state: "running",
             generation: "generation-1",
             turn_id: "turn-1"
           }

    assert facts.turns == [@captured]
    assert facts.desired == @desired
  end

  test "desired model, effort and location are inferred only for an exact contract match" do
    matching = %{@desired | provider: "claude", config_revision: "applied-revision"}

    assert %{
             applied: %{model: "gpt-5.6-sol", effort: "high", working_dir: "/tmp/desired"}
           } =
             ExecutionFacts.project(matching, process(:idle, "applied-revision"), [])

    assert %{applied: %{model: nil, effort: nil, working_dir: nil}} =
             ExecutionFacts.project(@desired, process(:idle, "applied-revision"), [])

    assert %{applied: %{model: nil, effort: nil, working_dir: nil}} =
             ExecutionFacts.project(
               %{matching | config_revision: "another-revision"},
               process(:idle, "applied-revision"),
               []
             )
  end

  test "live continuation identity correlates running and gated states" do
    for state <- [:running, :waiting_for_user, :awaiting_permission] do
      assert %{active: %{id: 41, lifecycle_state: lifecycle_state}} =
               ExecutionFacts.project(@desired, process(state, "applied-revision"), [@captured])

      assert lifecycle_state == to_string(state)
    end
  end

  test "idle continuations do not relabel the base process with turn overrides" do
    matching = %{@desired | provider: "claude", config_revision: "applied-revision"}

    assert %{
             active: nil,
             applied: %{
               model: "gpt-5.6-sol",
               effort: "high",
               working_dir: "/tmp/desired"
             },
             turns: [@captured]
           } =
             ExecutionFacts.project(matching, process(:idle, "applied-revision"), [@captured])
  end

  test "a paused process still reports the physical provider job it retains" do
    matching = %{@desired | provider: "claude", config_revision: "applied-revision"}

    assert %{
             active: %{id: 41, state: "executing", lifecycle_state: "paused"},
             applied: %{
               model: "gpt-5.6-sol",
               effort: "high",
               working_dir: "/tmp/desired"
             }
           } = ExecutionFacts.project(matching, process(:paused, "applied-revision"), [@captured])

    completed = %{@captured | state: "completed"}

    assert %{active: nil, turns: [^completed]} =
             ExecutionFacts.project(matching, process(:paused, "applied-revision"), [completed])
  end

  test "active turn keeps its captured revision and reports the process comparison separately" do
    matching_turn = %{@captured | config_revision: "applied-revision"}

    assert %{
             active: %{
               config_revision: "applied-revision",
               process_revision: "applied-revision",
               revision_mismatch: false
             },
             turns: [^matching_turn]
           } =
             ExecutionFacts.project(@desired, process(:running, "applied-revision"), [
               matching_turn
             ])

    legacy_turn = %{@captured | config_revision: nil}

    assert %{
             active: %{
               config_revision: nil,
               process_revision: "applied-revision",
               revision_mismatch: nil
             },
             turns: [^legacy_turn]
           } =
             ExecutionFacts.project(@desired, process(:running, "applied-revision"), [legacy_turn])
  end

  test "read snapshots the live continuation before querying its durable turn" do
    {:ok, snapshot} = Agent.start_link(fn -> [] end)

    process_reader = fn ->
      Agent.update(snapshot, fn [] -> [@captured] end)
      process(:running, "applied-revision")
    end

    turns_reader = fn -> Agent.get(snapshot, & &1) end

    assert %{active: %{id: 41}, turns: [@captured]} =
             ExecutionFacts.read("agent",
               routine: nil,
               process: process_reader,
               turns: turns_reader
             )
  end

  test "a continuation without durable identity cannot claim an uncorrelated legacy turn" do
    legacy = %{@captured | generation: nil, turn_id: nil}

    unidentified =
      process(:running, "applied-revision")
      |> put_in([:continuation, :agent_generation], nil)
      |> put_in([:continuation, :agent_turn_id], nil)

    assert %{active: nil, turns: [^legacy]} =
             ExecutionFacts.project(@desired, unidentified, [legacy])
  end

  defp process(state, revision) do
    %{
      provider: "claude",
      state: state,
      config_revision: revision,
      continuation: %{
        agent_generation: "generation-1",
        agent_turn_id: "turn-1",
        outcome: :running
      }
    }
  end
end
