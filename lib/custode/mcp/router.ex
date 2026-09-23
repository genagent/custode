defmodule Custode.MCP.Router do
  @moduledoc false

  use Plug.Router

  alias Anubis.Server.Transport.StreamableHTTP
  alias Custode.MCP.{Capabilities, Identity}

  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # #1 + #2: no request proceeds without a verified bearer token, and the
  # resolved identity rides Plug assigns -- which anubis inherits into
  # every tool's frame.assigns. Localhost is no longer the only wall.
  def authenticate(conn, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, identity} <- Identity.verify(token) do
      conn
      |> Plug.Conn.assign(:custode_identity, identity)
      |> Plug.Conn.assign(:custode_transport, origin_transport(conn, identity))
    else
      _missing_or_invalid ->
        conn
        |> Plug.Conn.send_resp(401, "missing or invalid bearer token")
        |> Plug.Conn.halt()
    end
  end

  # Origin is audit attribution, not a caller claim: only the verified
  # operator token used by mix custode may distinguish CLI-over-MCP.
  defp origin_transport(conn, %{kind: :operator}) do
    case Plug.Conn.get_req_header(conn, "x-custode-origin") do
      ["cli"] -> :cli
      _other -> :mcp
    end
  end

  defp origin_transport(_conn, _identity), do: :mcp

  # Not `forward`: the Anubis plug's init opts contain closures, which Plug's
  # compile-time forward cannot escape. Init at runtime instead.
  match "/mcp" do
    dispatch_endpoint(conn, :main, Custode.MCP.Server)
  end

  # The memory-only server sub-agents are pointed at.
  match "/mcp/memory" do
    dispatch_endpoint(conn, :memory, Custode.MCP.MemoryServer)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp dispatch_endpoint(conn, endpoint, server) do
    case Capabilities.authorize_endpoint(endpoint, conn.assigns.custode_identity) do
      :ok ->
        opts = StreamableHTTP.Plug.init(server: server)
        StreamableHTTP.Plug.call(conn, opts)

      {:error, reason} ->
        conn
        |> Plug.Conn.send_resp(403, reason)
        |> Plug.Conn.halt()
    end
  end
end
