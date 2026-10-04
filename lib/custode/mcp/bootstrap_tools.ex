defmodule Custode.MCP.BootstrapTools do
  @moduledoc """
  The MCP surface for `Custode.Operator.Bootstrap` (#647).

  Registered on the main server but named in none of `Custode.MCP.Capabilities`'
  routine lists, so only the operator, who is authorized for every tool, can
  discover it. The handler refuses any other caller as well, because discovery
  is a courtesy and the check that matters is the one at the call.
  """
end

defmodule Custode.MCP.BootstrapTools.OperatorBootstrap do
  @moduledoc """
  One read for a newly connected operator session: which instance this is, who
  the caller is and over which transport, the effective authority, a compact
  fleet summary, and the operations to expand it. Read-only: it never creates
  or replaces the installation id, and reports a tool error when boot could not
  provision one.
  """
  use Custode.MCP.Tool, name: "operator_bootstrap"

  import Custode.MCP.Tools

  alias Custode.Operator.{Authority, Bootstrap}

  input_schema(%{"properties" => %{}, "type" => "object"})

  @impl true
  def execute(_params, frame) do
    caller = Custode.MCP.caller(frame)

    with :ok <- Authority.human(caller),
         {:ok, result} <-
           Bootstrap.build(caller,
             transport: Custode.MCP.origin_transport(frame),
             verified: verified?(frame)
           ) do
      reply(frame, result)
    else
      {:error, {:installation_unavailable, reason}} ->
        fail(
          frame,
          "installation id unavailable (#{inspect(reason)}): Custode could not persist " <>
            "its installation id at boot; check the log and restart"
        )

      {:error, message} ->
        fail(frame, message)
    end
  end

  # `Custode.MCP.caller/1` falls back to the operator for a direct call with no
  # request context. Only an identity the router attached was authenticated.
  defp verified?(%{assigns: %{custode_identity: _identity}}), do: true
  defp verified?(_frame), do: false
end
