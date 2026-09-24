defmodule Custode.CLI.DoctorTest do
  # The install preflight (#161): checks/0 must be runnable on any machine
  # without a server and report shape-compatibly with ObanClaude's doctor.
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, uid: 1]

  test "every check reports as {label, {:ok, _} | {:error, _}}" do
    for {label, result} <- Custode.CLI.Doctor.checks() do
      assert is_binary(label)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  test "the report renders ok and failure lines through the shared shape" do
    {text, ok?} =
      ObanClaude.CLI.Doctor.report([
        {"something", {:ok, "fine"}},
        {"broken", {:error, :nope}}
      ])

    refute ok?
    assert text =~ "[ok]   something"
    assert text =~ "[FAIL] broken"
  end

  test "a home that cannot be created reports an error, not a raise" do
    # on_exit, not try/after: cleanup must survive the test process dying
    # (a linked-probe crash once leaked this env var into routine_test)
    previous = System.get_env("CUSTODE_HOME")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("CUSTODE_HOME")
        val -> System.put_env("CUSTODE_HOME", val)
      end
    end)

    System.put_env("CUSTODE_HOME", "/dev/null/nope")

    {_label, result} =
      Custode.CLI.Doctor.checks() |> Enum.find(fn {l, _} -> l =~ "home" end)

    assert match?({:error, _}, result)
  end

  test "managed settings that drop custode's allow rules warn without failing the run" do
    root = Path.join(System.tmp_dir!(), uid("doctor-managed"))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, "remote-settings.json"),
      Jason.encode!(%{
        "allowManagedPermissionRulesOnly" => true,
        "permissions" => %{"disableBypassPermissionsMode" => "disable"}
      })
    )

    put_env!(:claude_managed_settings, config_dir: root, system_dir: Path.join(root, "system"))

    managed =
      Custode.CLI.Doctor.checks()
      |> Enum.filter(fn {label, _} -> label =~ "claude managed" or label =~ "bypass" end)

    assert [{_, {:ok, "warning: " <> rules}}, {_, {:ok, "warning: " <> bypass}}] = managed
    assert rules =~ "no managed allow rule matches the custode MCP server"
    assert bypass =~ "disableBypassPermissionsMode"
    assert {_text, true} = ObanClaude.CLI.Doctor.report(managed)
  end
end
