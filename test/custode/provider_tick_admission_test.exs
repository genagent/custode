defmodule Custode.ProviderTickAdmissionTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{ConversationArcs, ProviderTickAdmission, Routine}

  test "both providers are configured before their Tick workers run" do
    assert Application.fetch_env!(:oban_claude, :tick_admission) == ProviderTickAdmission
    assert Application.fetch_env!(:oban_codex, :tick_admission) == ProviderTickAdmission
  end

  test "only a Tick carrying the current provider and delivery revision reaches delivery" do
    routine = routine_fixture!(tmp_workspace!(), %{provider: :claude})
    delivery_revision = Routine.delivery_revision(routine)
    parent = self()

    deliver = fn ->
      send(parent, :delivered)
      :ok
    end

    assert :ok = ProviderTickAdmission.admit(:claude, routine.id, delivery_revision, deliver)
    assert_receive :delivered

    assert {:cancel, {:stale_tick, id}} =
             ProviderTickAdmission.admit(:claude, routine.id, "stale", deliver)

    assert id == routine.id

    assert {:cancel, {:stale_tick, id}} =
             ProviderTickAdmission.admit(:codex, routine.id, delivery_revision, deliver)

    assert id == routine.id

    assert {:cancel, {:config_reconcile_failed, id, :invalid_expected_execution_config}} =
             ProviderTickAdmission.admit(:claude, routine.id, nil, deliver)

    assert id == routine.id
    refute_receive :delivered
  end

  test "a refused prelaunch tick closes its exact conversation arc" do
    routine = routine_fixture!(tmp_workspace!(), %{provider: :claude})

    assert {:ok, _args, prepared} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "scheduled:stale")

    assert {:cancel, {:stale_tick, id}} =
             ProviderTickAdmission.admit(
               :claude,
               routine.id,
               "stale",
               %{arc_id: prepared.arc_id},
               fn -> flunk("stale delivery must not run") end
             )

    assert id == routine.id

    assert [arc] = ConversationArcs.history(routine.id, "scheduled:stale")
    assert arc.state == "completed"
    assert arc.last_outcome == "not_launched"
    assert arc.rotation_reason == "stale_tick"
  end

  test "a provider policy cancellation closes the arc without changing its result" do
    routine = routine_fixture!(tmp_workspace!(), %{provider: :claude})
    delivery_revision = Routine.delivery_revision(routine)

    assert {:ok, _args, prepared} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "scheduled:busy")

    assert {:cancel, :agent_busy} =
             ProviderTickAdmission.admit(
               :claude,
               routine.id,
               delivery_revision,
               %{arc_id: prepared.arc_id},
               fn -> {:cancel, :agent_busy} end
             )

    assert [arc] = ConversationArcs.history(routine.id, "scheduled:busy")
    assert arc.state == "completed"
    assert arc.last_outcome == "not_launched"
    assert arc.rotation_reason == "provider_cancelled"
  end
end
