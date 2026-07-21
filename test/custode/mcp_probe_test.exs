defmodule Custode.MCP.ProbeTest do
  use ExUnit.Case, async: false

  alias Custode.MCP.Probe

  test "ready?/0 succeeds against the running test MCP server" do
    # the test env boots the real MCP stack on its own port; a passing probe
    # here is the same signal the boot gate waits for in prod
    assert Probe.ready?()
    assert Probe.await_ready(3) == :ok
  end

  test "run/0 no-ops when no ticks queue is configured (the test env shape)" do
    assert Probe.run() == :ok
  end

  test "doctor/0 passes when both probes answer, and names what failed (#15)" do
    Application.put_env(:custode, :doctor_fun, fn
      :version -> {:ok, "1.0.0"}
      :auth -> {:ok, %{authenticated: true}}
    end)

    on_exit(fn -> Application.delete_env(:custode, :doctor_fun) end)
    assert Probe.doctor() == :ok

    Application.put_env(:custode, :doctor_fun, fn
      :version -> {:ok, "1.0.0"}
      :auth -> {:error, :not_authenticated}
    end)

    assert {:error, report} = Probe.doctor()
    assert report =~ "claude auth"
    refute report =~ "binary"
  end

  test "await_ready/1 times out when attempts run dry" do
    # point the probe at a dead port for one cycle
    original = Application.get_env(:custode, :mcp_port)
    Application.put_env(:custode, :mcp_port, 1)
    on_exit(fn -> Application.put_env(:custode, :mcp_port, original) end)

    assert Probe.await_ready(0) == :timeout
    refute Probe.ready?()
  end
end
