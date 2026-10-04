defmodule Custode.MCP.Router do
  @moduledoc false

  @behaviour Plug

  alias Custode.MCP.{Capabilities, Identity}
  alias Custode.MCP.Snodo, as: SnodoTransport
  alias Snodo.Transport.Plug, as: SnodoPlug

  @impl Plug
  def init(_opts), do: SnodoTransport.plug_options()

  @impl Plug
  def call(conn, catalogs) do
    conn
    |> authenticate()
    |> observe_response()
    |> dispatch(catalogs)
  end

  defp observe_response(%Plug.Conn{halted: true} = conn), do: conn

  defp observe_response(conn) do
    Plug.Conn.register_before_send(conn, fn prepared ->
      body = IO.iodata_to_binary(prepared.resp_body || "")

      if byte_size(body) <= 100_000,
        do: Plug.Conn.assign(prepared, :custode_response_body, body),
        else: prepared
    end)
  end

  # #1 + #2: no request proceeds without a verified bearer token, and the
  # resolved identity rides trusted Plug assigns into every tool context.
  def authenticate(conn, _opts \\ []) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, identity} <- Identity.verify(token) do
      origin = origin_transport(conn, identity)
      delivery_id = Ecto.UUID.generate()

      conn
      |> Plug.Conn.assign(:custode_identity, identity)
      |> Plug.Conn.assign(:custode_transport, origin)
      |> Plug.Conn.assign(:custode_delivery_id, delivery_id)
      |> Plug.Conn.assign(:mcp_auth, %{
        identity: identity,
        origin: origin,
        delivery_id: delivery_id
      })
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

  defp dispatch(%Plug.Conn{halted: true} = conn, _catalogs), do: conn

  defp dispatch(%Plug.Conn{request_path: path} = conn, catalogs)
       when path in ["/mcp", "/mcp/memory"] do
    endpoint = if path == "/mcp", do: :main, else: :memory

    case Capabilities.authorize_endpoint(endpoint, conn.assigns.custode_identity) do
      :ok ->
        SnodoPlug.call(conn, Map.fetch!(catalogs, path)) |> Custode.ContextReceipts.emitted()

      {:error, reason} ->
        conn
        |> Plug.Conn.send_resp(403, reason)
        |> Plug.Conn.halt()
    end
  end

  defp dispatch(conn, _catalogs), do: Plug.Conn.send_resp(conn, 404, "not found")
end
