defmodule Custode.ExternalMCPTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  test "no external servers: single config path, no extra grants" do
    put_env!(:external_mcp_servers, [])

    assert Custode.MCP.config_paths("x") == [Custode.MCP.config_path("x")]
    assert Custode.MCP.external_allowed() == []
  end

  test "explicit read integrations are captured in a routine native config" do
    put_env!(:external_mcp_servers, [
      %{
        name: "hexpm",
        type: :http,
        url: "https://hexpm-mcp.fly.dev/mcp",
        read_only: true,
        allowed: ["mcp__hexpm__info"]
      },
      %{
        name: "cratesio",
        type: :http,
        url: "https://cratesio-mcp.fly.dev/",
        read_only: true,
        allowed: ["mcp__cratesio__get_crate_info"]
      }
    ])

    assert Custode.MCP.config_paths("x") == [
             Custode.MCP.config_path("x"),
             Custode.MCP.external_config_path()
           ]

    assert Custode.MCP.external_allowed() == ["mcp__hexpm__info", "mcp__cratesio__get_crate_info"]

    routine = routine_fixture!(tmp_workspace!(), %{mcp: true, role: :backlog_worker})
    claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

    refute Custode.MCP.external_config_path() in claude_args["mcp_config"]
    assert length(claude_args["mcp_config"]) == 2
    assert claude_args["strict_mcp_config"]
    assert "mcp__hexpm__info" in claude_args["allowed_tools"]
    assert "mcp__cratesio__get_crate_info" in claude_args["allowed_tools"]
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
