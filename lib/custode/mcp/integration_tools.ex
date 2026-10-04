defmodule Custode.MCP.IntegrationTools do
  @moduledoc false
  def verified_actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
      when kind in [:operator, :routine, :sub_agent] and is_binary(id) and id != "",
      do: {:ok, actor}

  def verified_actor(_frame), do: {:error, :unauthenticated}
end

defmodule Custode.MCP.IntegrationTools.List do
  @moduledoc "Read caller-filtered integration configuration and explicit unsupported/denied reasons."
  use Custode.MCP.Tool, name: "integration_list"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  alias Custode.IntegrationCatalog
  alias Custode.MCP.IntegrationTools

  input_schema(%{
    "type" => "object",
    "properties" => %{
      "provider" => %{
        "type" => "string",
        "enum" => ["claude", "codex"],
        "description" => "Client whose transport support to inspect; default claude."
      }
    }
  })

  @impl true
  def execute(params, frame) do
    with {:ok, actor} <- IntegrationTools.verified_actor(frame),
         {:ok, facts} <-
           IntegrationCatalog.inspect_for(actor, Map.get(params, :provider, "claude")) do
      reply(frame, facts)
    else
      {:error, reason} -> fail(frame, "integration catalog unavailable: #{inspect(reason)}")
    end
  end
end

defmodule Custode.MCP.IntegrationTools.UpdateAccess do
  @moduledoc "Human-only revision-checked enable/deny update for an existing integration."
  use Custode.MCP.Tool, name: "integration_access_update"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  alias Custode.IntegrationCatalog
  alias Custode.MCP.IntegrationTools

  input_schema(%{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "expected_revision" => %{"type" => "string"},
      "request_id" => %{"type" => "string"},
      "enabled" => %{"type" => "boolean"},
      "denied_agents" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["name", "expected_revision", "request_id"]
  })

  @impl true
  def execute(params, frame) do
    settings =
      for key <- [:enabled, :denied_agents],
          Map.has_key?(params, key),
          into: %{},
          do: {to_string(key), Map.fetch!(params, key)}

    with {:ok, actor} <- IntegrationTools.verified_actor(frame),
         {:ok, facts} <-
           IntegrationCatalog.update_access(
             actor,
             params[:name],
             params[:expected_revision],
             params[:request_id],
             settings
           ) do
      reply(frame, facts)
    else
      {:error, reason} -> fail(frame, "integration access update refused: #{inspect(reason)}")
    end
  end
end
