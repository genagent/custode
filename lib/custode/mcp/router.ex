defmodule Custode.MCP.Router do
  @moduledoc false

  use Plug.Router

  alias Anubis.Server.Transport.StreamableHTTP
  alias Custode.MCP.Identity

  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # #1 + #2: no request proceeds without a verified bearer token, and the
  # resolved identity rides Plug assigns -- which anubis inherits into
  # every tool's frame.assigns. Localhost is no longer the only wall.
  def authenticate(conn, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, identity} <- Identity.verify(token) do
      Plug.Conn.assign(conn, :custode_identity, identity)
    else
      _missing_or_invalid ->
        conn
        |> Plug.Conn.send_resp(401, "missing or invalid bearer token")
        |> Plug.Conn.halt()
    end
  end

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
