defmodule Custode.RoutineTickTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.RoutineTick

  # the Tick jobs RoutineTick enqueues for one agent, newest first (queues
  # are empty in test config, so they insert and sit there for inspection;
  # the oban_jobs table is shared across the suite, so always scope by id)
  defp ticks_for(agent_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "ObanClaude.Agent.Tick",
        where: fragment("json_extract(?, '$.agent_id')", j.args) == ^agent_id,
        order_by: [desc: j.id]
      )
    )
  end

  test "resolves the routine's current args at fire time, not at boot" do
    workspace = tmp_workspace!()
    id = uid("drift")

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "original", model: "haiku"}
    ])

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})

    first = hd(ticks_for(id))
    assert first.args["agent_id"] == id
    assert first.args["prompt"] == "original"
    assert first.args["start"]["args"]["model"] == "haiku"

    # edit the routine's prompt and model WITHOUT restarting: the next fire
    # must pick up the new config (the whole point of #7)
    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "revised", model: "sonnet"}
    ])

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})

    second = hd(ticks_for(id))
    assert second.id != first.id
    assert second.args["prompt"] == "revised"
    assert second.args["start"]["args"]["model"] == "sonnet"
  end

  test "cancels when the routine no longer exists" do
    ghost = uid("ghost")

    assert {:cancel, {:unknown_routine, ^ghost}} =
             RoutineTick.perform(%Oban.Job{args: %{"routine_id" => ghost}})

    assert ticks_for(ghost) == []
  end

  test "cancels on a malformed job with no routine_id" do
    assert {:cancel, {:invalid_routine_tick, _}} =
             RoutineTick.perform(%Oban.Job{args: %{}})
  end
end
