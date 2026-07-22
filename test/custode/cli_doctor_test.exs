defmodule Custode.CLI.DoctorTest do
  # The install preflight (#161): checks/0 must be runnable on any machine
  # without a server and report shape-compatibly with ObanClaude's doctor.
  use ExUnit.Case, async: false

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
end
