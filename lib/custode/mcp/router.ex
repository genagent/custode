defmodule Custode.MCP.Router do
  @moduledoc false

  use Plug.Router

  alias Anubis.Server.Transport.StreamableHTTP

  plug(:match)
  plug(:dispatch)

  # Not `forward`: the Anubis plug's init opts contain closures, which Plug's
  # compile-time forward cannot escape. Init at runtime instead.
  match "/mcp" do
    opts = StreamableHTTP.Plug.init(server: Custode.MCP.Server)
    StreamableHTTP.Plug.call(conn, opts)
  end

  # The memory-only server sub-agents are pointed at.
  match "/mcp/memory" do
    opts = StreamableHTTP.Plug.init(server: Custode.MCP.MemoryServer)
    StreamableHTTP.Plug.call(conn, opts)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
