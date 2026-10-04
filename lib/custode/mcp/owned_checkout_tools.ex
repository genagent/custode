defmodule Custode.MCP.OwnedCheckoutTools do
  @moduledoc false

  import Custode.MCP.Tools

  def options(params, frame) do
    [
      actor: Custode.MCP.caller(frame),
      transport: Custode.MCP.origin_transport(frame),
      idempotency_key: params[:idempotency_key] || Ecto.UUID.generate(),
      dry_run: params[:dry_run] || false
    ]
  end

  def respond({:ok, %{result: result}}, frame) when is_map(result), do: reply(frame, result)

  def respond({:ok, response}, frame) do
    reply(frame, %{status: response.status, effect_preview: response.effect_preview})
  end

  def respond({:error, reason}, frame),
    do: fail(frame, "owned checkout failed: #{inspect(reason)}")
end

defmodule Custode.MCP.OwnedCheckoutTools.Provision do
  @moduledoc "Provision a routine-owned repository clone at its deterministic path."
  use Custode.MCP.Tool, name: "provision_owned_checkout"

  alias Custode.MCP.OwnedCheckoutTools
  alias Custode.Operations.Fleet.ProvisionOwnedCheckout, as: Operation

  input_schema(%{
    "properties" => %{
      "dry_run" => %{
        "description" => "preview without changing the filesystem",
        "type" => "boolean"
      },
      "idempotency_key" => %{
        "description" => "stable key for one logical provision",
        "type" => "string"
      },
      "repository" => %{"description" => "GitHub owner/name", "type" => "string"},
      "routine_id" => %{"description" => "future or existing routine id", "type" => "string"}
    },
    "required" => ["repository", "routine_id"],
    "type" => "object"
  })

  def definition, do: Operation.definition()
  def name, do: definition().projection.mcp.name

  @impl true
  def execute(%{routine_id: id, repository: repository} = params, frame) do
    id
    |> Operation.dispatch(repository, OwnedCheckoutTools.options(params, frame))
    |> OwnedCheckoutTools.respond(frame)
  end
end

defmodule Custode.MCP.OwnedCheckoutTools.Refresh do
  @moduledoc "Safely fetch and fast-forward a configured routine-owned checkout."
  use Custode.MCP.Tool, name: "refresh_owned_checkout"

  alias Custode.MCP.OwnedCheckoutTools
  alias Custode.Operations.Fleet.RefreshOwnedCheckout, as: Operation

  input_schema(%{
    "properties" => %{
      "dry_run" => %{
        "description" => "preview without fetching or fast-forwarding",
        "type" => "boolean"
      },
      "idempotency_key" => %{
        "description" => "stable key for one logical refresh",
        "type" => "string"
      },
      "routine_id" => %{"description" => "configured routine id", "type" => "string"}
    },
    "required" => ["routine_id"],
    "type" => "object"
  })

  def definition, do: Operation.definition()
  def name, do: definition().projection.mcp.name

  @impl true
  def execute(%{routine_id: id} = params, frame) do
    id
    |> Operation.dispatch(OwnedCheckoutTools.options(params, frame))
    |> OwnedCheckoutTools.respond(frame)
  end
end
