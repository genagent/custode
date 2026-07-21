defmodule Custode.ExternalMCPTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  test "no external servers: single config path, no extra grants" do
    put_env!(:external_mcp_servers, [])

    assert Custode.MCP.config_paths("x") == [Custode.MCP.config_path("x")]
    assert Custode.MCP.external_allowed() == []
  end

  test "configured servers land in every mcp routine's config list and allowlist" do
    put_env!(:external_mcp_servers, [
      %{name: "hexpm", type: :http, url: "https://hexpm-mcp.fly.dev/mcp"},
      %{name: "cratesio", type: :http, url: "https://cratesio-mcp.fly.dev/"}
    ])

    assert Custode.MCP.config_paths("x") == [
             Custode.MCP.config_path("x"),
             Custode.MCP.external_config_path()
           ]

    assert Custode.MCP.external_allowed() == ["mcp__hexpm", "mcp__cratesio"]

    routine = routine_fixture!(tmp_workspace!(), %{mcp: true, role: :backlog_worker})
    claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

    assert Custode.MCP.external_config_path() in claude_args["mcp_config"]
    assert "mcp__hexpm" in claude_args["allowed_tools"]
    assert "mcp__cratesio" in claude_args["allowed_tools"]
  end

  test "write_config! emits the external file with the declared servers" do
    put_env!(:external_mcp_servers, [
      %{name: "hexpm", type: :http, url: "https://hexpm-mcp.fly.dev/mcp"},
      %{name: "local-thing", type: :stdio, command: "thing-mcp", args: ["--stdio"]}
    ])

    Custode.MCP.write_config!()
    on_exit(fn -> File.rm(Custode.MCP.external_config_path()) end)

    external = Custode.MCP.external_config_path() |> File.read!() |> Jason.decode!()
    assert %{"url" => "https://hexpm-mcp.fly.dev/mcp"} = external["mcpServers"]["hexpm"]
    assert %{"command" => "thing-mcp"} = external["mcpServers"]["local-thing"]
  end

  test "an explicit allowed list overrides the default whole-server grant" do
    put_env!(:external_mcp_servers, [
      %{name: "hexpm", type: :http, url: "https://x", allowed: ["mcp__hexpm__info"]}
    ])

    assert Custode.MCP.external_allowed() == ["mcp__hexpm__info"]
  end
end
