defmodule Custode.AgentHandoffIntentTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.AgentHandoffIntent

  test "pause context is durably upserted and cleared by agent id" do
    id = uid("handoff-intent")

    assert AgentHandoffIntent.get(id) == nil
    assert :ok = AgentHandoffIntent.put(id, %{cause: :emergency_pause, reason: :operator})

    assert AgentHandoffIntent.get(id) == %{
             "cause" => "emergency_pause",
             "reason" => "operator"
           }

    assert :ok = AgentHandoffIntent.put(id, %{cause: :pause_after_turn, reason: :spend_rail})

    assert AgentHandoffIntent.get(id) == %{
             "cause" => "pause_after_turn",
             "reason" => "spend_rail"
           }

    assert :ok = AgentHandoffIntent.clear(id)
    assert AgentHandoffIntent.get(id) == nil
  end

  test "absent routine intents are swept without touching configured ids" do
    kept = uid("handoff-intent-kept")
    removed = uid("handoff-intent-removed")

    assert :ok = AgentHandoffIntent.put(kept, %{cause: :emergency_pause, reason: :operator})
    assert :ok = AgentHandoffIntent.put(removed, %{cause: :emergency_pause, reason: :operator})

    assert :ok = AgentHandoffIntent.clear_absent([kept])
    assert is_map(AgentHandoffIntent.get(kept))
    assert AgentHandoffIntent.get(removed) == nil

    assert :ok = AgentHandoffIntent.clear(kept)
  end
end
