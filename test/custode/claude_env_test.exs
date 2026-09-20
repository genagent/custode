defmodule Custode.ClaudeEnvTest do
  # the OS environment is global
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.ClaudeEnv

  defp var, do: "CUSTODE_TEST_ENV_" <> (uid("v") |> String.upcase() |> String.replace("-", "_"))

  test "sets a configured variable, because an agent's claude inherits the node's environment" do
    name = var()
    on_exit(fn -> System.delete_env(name) end)
    put_env!(:claude_env, %{name => "false"})

    assert ClaudeEnv.apply!() == %{name => "false"}
    assert System.get_env(name) == "false"
  end

  test "a variable the operator already exported wins" do
    name = var()
    System.put_env(name, "auto:20")
    on_exit(fn -> System.delete_env(name) end)
    put_env!(:claude_env, %{name => "false"})

    assert ClaudeEnv.apply!() == %{}
    assert System.get_env(name) == "auto:20"
  end

  # the live failure this exists for (#483): agents called custode tools
  # blind and a sweep went unjournaled
  test "the default turns the CLI's tool search off" do
    Application.delete_env(:custode, :claude_env)
    on_exit(fn -> Application.put_env(:custode, :claude_env, %{}) end)

    assert ClaudeEnv.configured() == %{"ENABLE_TOOL_SEARCH" => "false"}
  end

  test "an empty configuration sets nothing" do
    put_env!(:claude_env, %{})
    assert ClaudeEnv.apply!() == %{}
  end
end
