defmodule Custode.CLI.Client do
  @moduledoc """
  ## Why a bare Req poster and not Anubis.Client (#156, decided 2026-07-22)

  Anubis.Client is the right client for anything LONG-LIVED -- it brings
  supervision, session initialization, protocol negotiation, and pooled
  HTTP, and the federation direction (design 002) should use it from day
  one. A one-shot `mix custode <cmd>` VM is the opposite shape: total
  invocation latency measures ~0.53s and is dominated by VM boot; the
  poster's own work is microseconds; and the client's environment (a
  started application with Finch pools and a client supervisor) is real
  integration weight for a process that lives two seconds. Spike data on
  the issue. This module therefore stays deliberately thin -- and if it
  ever grows session resumption, notifications, or capability logic, that
  is the signal it wants to become an Anubis.Client after all.

  The CLI's transport (#45): a minimal MCP streamable-HTTP client speaking
  to the RUNNING custode server over loopback. The mix task never starts
  the custode app (the server owns the ports and the database); it talks to
  the same operator tools every other agent does -- which makes each CLI
  invocation a live integration test of the MCP surface.
  """

  alias Custode.MCP.Identity

  @headers [{"accept", "application/json, text/event-stream"}]

  @doc "Call one tool on the running server: `{:ok, decoded}` | `{:error, text}`."
  def call(tool, arguments \\ %{}) do
    url = url()

    with {:ok, session_id} <- initialize(url),
         :ok <- initialized(url, session_id) do
      tool_call(url, session_id, tool, arguments)
    end
  end

  def url do
    port =
      System.get_env("CUSTODE_MCP_PORT") ||
        to_string(Application.get_env(:custode, :mcp_port, 6161))

    "http://127.0.0.1:#{port}/mcp"
  end

  defp initialize(url) do
    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "mix-custode", version: "0"}
      }
    }

    case post(url, body, []) do
      {:ok, %Req.Response{status: 200} = response} ->
        case Req.Response.get_header(response, "mcp-session-id") do
          [session_id | _rest] -> {:ok, session_id}
          [] -> {:error, "server answered without an mcp-session-id"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "server answered #{status} on initialize"}

      {:error, _reason} ->
        {:error, "custode server unreachable at #{url} -- is it running?"}
    end
  end

  defp initialized(url, session_id) do
    case post(url, %{jsonrpc: "2.0", method: "notifications/initialized"}, session_id) do
      {:ok, _response} -> :ok
      {:error, _reason} -> {:error, "session handshake failed"}
    end
  end

  defp tool_call(url, session_id, tool, arguments) do
    body = %{
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: %{name: tool, arguments: arguments}
    }

    with {:ok, %Req.Response{status: 200, body: raw}} <- post(url, body, session_id),
         %{"result" => result} <- decode(raw) do
      unpack(result)
    else
      {:ok, %Req.Response{status: status}} -> {:error, "tools/call answered #{status}"}
      %{"error" => %{"message" => message}} -> {:error, message}
      {:error, _reason} -> {:error, "lost the server mid-call"}
      other -> {:error, "unexpected reply: #{inspect(other)}"}
    end
  end

  defp post(url, body, session_id) do
    headers =
      case session_id do
        id when is_binary(id) -> [{"mcp-session-id", id} | auth_headers()]
        _none -> auth_headers()
      end

    Req.post(url,
      json: body,
      headers: headers,
      retry: false,
      connect_options: [timeout: 2_000],
      receive_timeout: 30_000
    )
  end

  # #1: the CLI is an OPERATOR -- its token comes from the boot-written
  # 0600 file (or CUSTODE_OPERATOR_TOKEN); without it the server 401s.
  defp auth_headers do
    case Identity.operator_token() do
      {:ok, token} -> [{"authorization", "Bearer " <> token} | @headers]
      {:error, _reason} -> @headers
    end
  end

  # the reply is either plain JSON or an SSE frame ("data: {...}")
  defp decode(body) when is_map(body), do: body

  defp decode(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> data -> Jason.decode!(data)
      _line -> nil
    end)
    |> Kernel.||(Jason.decode!(body))
  end

  # tool replies carry their JSON as text content; errors carry the message
  defp unpack(%{"isError" => true, "content" => [%{"text" => text} | _rest]}),
    do: {:error, text}

  defp unpack(%{"content" => [%{"text" => text} | _rest]}), do: {:ok, Jason.decode!(text)}
  defp unpack(other), do: {:error, "unexpected tool reply: #{inspect(other)}"}
end
