defmodule Custode.DrainToolTest do
  # The async drain surface (#132): pause-now-reply-now, operator-only, the
  # background wait through the real Custode.drain seams is NOT exercised
  # here (DrainTest owns that) -- this is the tool contract.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.Tools.Drain

  @operator %Anubis.Server.Frame{}

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  setup do
    path = Path.join(System.tmp_dir!(), uid("drain-tool-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "the operator's call pauses, replies immediately, and hands off to the drain" do
    test_pid = self()
    put_env!(:drain_fun, fn opts -> send(test_pid, {:drained, opts}) end)

    json = tool_json(Drain.execute(%{timeout_ms: 5_000}, @operator))

    assert json["draining"] == true
    assert is_integer(json["executing"])
    assert json["note"] =~ "queues paused"

    # the background task got the wait+stop with the timeout threaded
    assert_receive {:drained, opts}, 2_000
    assert opts[:timeout] == 5_000
    assert opts[:queues] == []
  end

  test "agents are refused at the verb" do
    refused = tool_error(Drain.execute(%{}, routine_frame("custode")))
    assert refused =~ "requires the human operator"
  end
end
