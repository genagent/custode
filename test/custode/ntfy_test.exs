defmodule Custode.NtfyTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  setup do
    test_pid = self()
    put_env!(:ntfy_sink, fn message -> send(test_pid, {:ntfy, message}) end)
    :ok
  end

  test "disabled without a topic" do
    put_env!(:ntfy, topic: nil)
    :ok = Custode.Ntfy.publish(%{"event" => "needs_approval", "agent" => "a"})
    refute_receive {:ntfy, _message}, 100
  end

  test "attention events ring; ordinary entries accumulate silently under :all" do
    put_env!(:ntfy, topic: "custode-test", publish: :all)

    :ok =
      Custode.Ntfy.publish(%{"event" => "needs_approval", "agent" => "rt", "action" => "fix #9"})

    assert_receive {:ntfy, urgent}, 500
    assert urgent.priority == 4
    assert urgent.title == "rt needs_approval"
    assert urgent.body == "fix #9"
    assert urgent.url == "https://ntfy.sh/custode-test"
    assert urgent.click =~ "/console/rt"

    :ok = Custode.Ntfy.publish(%{"event" => "turn", "agent" => "rt", "summary" => "swept"})
    assert_receive {:ntfy, quiet}, 500
    assert quiet.priority == 1
    assert quiet.body == "swept"
  end

  test ":attention mode drops ordinary entries and keeps alerts" do
    put_env!(:ntfy, topic: "custode-test", publish: :attention)

    :ok = Custode.Ntfy.publish(%{"event" => "turn", "agent" => "rt", "summary" => "swept"})
    refute_receive {:ntfy, _message}, 100

    :ok = Custode.Ntfy.publish(%{"event" => "budget_paused", "agent" => "rt"})
    assert_receive {:ntfy, _alert}, 500
  end

  test "a failing sensor rings once, on the run that crosses the threshold (#444)" do
    put_env!(:ntfy, topic: "custode-test", publish: :attention)
    entry = %{"event" => "sensor_failed", "agent" => "rt", "summary" => "ci-rt: fetch failed"}

    # a blip before the threshold, and the same news again after it: both quiet
    :ok = Custode.Ntfy.publish(Map.put(entry, "crossed_threshold", false))
    refute_receive {:ntfy, _message}, 100

    :ok = Custode.Ntfy.publish(Map.put(entry, "crossed_threshold", true))
    assert_receive {:ntfy, ring}, 500
    assert ring.priority == 4
    assert ring.title == "rt sensor_failed"
    assert ring.body == "ci-rt: fetch failed"
  end

  test "feed writes flow through the publisher" do
    put_env!(:ntfy, topic: "custode-test", publish: :all)
    agent = uid("ntfy-feed")

    Custode.Feed.record(%{event: "turn", agent: agent, summary: "from the feed"})

    assert_receive {:ntfy, message}, 500
    assert message.body == "from the feed"
    assert message.title == "#{agent} turn"
  end
end
