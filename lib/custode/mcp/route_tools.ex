defmodule Custode.MCP.RouteTools.Preview do
  @moduledoc "Preview an exact configured route and retain its shadow decision; never launch work."
  use Custode.MCP.Tool, name: "route_preview"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]
  alias Custode.RoutePreview

  input_schema(%{
    "type" => "object",
    "properties" => %{
      "request" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" =>
          ~w(request_id task_id input_revision class phase candidate_ids required_tools required_capabilities isolation context_refs limits),
        "properties" => %{
          "request_id" => %{"type" => "string"},
          "task_id" => %{"type" => "string"},
          "input_revision" => %{"type" => "string"},
          "class" => %{"type" => "string"},
          "phase" => %{"type" => "string", "enum" => ~w(plan execute verify)},
          "candidate_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "maxItems" => 20
          },
          "required_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
          "required_capabilities" => %{"type" => "array", "items" => %{"type" => "string"}},
          "isolation" => %{"type" => "string", "enum" => ~w(any read_only local)},
          "context_refs" => %{"type" => "array", "items" => %{"type" => "string"}},
          "context_provider" => %{"type" => "string", "enum" => ~w(claude codex)},
          "configured_route" => %{"type" => "string"},
          "pin" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => Map.new(~w(id provider model effort), &{&1, %{"type" => "string"}})
          },
          "limits" => %{
            "type" => "object",
            "required" => ~w(calls usd time_ms),
            "additionalProperties" => false,
            "properties" => %{
              "calls" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
              "usd" => %{"type" => "number", "exclusiveMinimum" => 0, "maximum" => 100},
              "time_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 3_600_000}
            }
          }
        }
      },
      "decision_id" => %{
        "type" => "string",
        "description" => "Read an existing decision instead of previewing a new request."
      }
    }
  })

  @impl true
  def execute(params, frame) do
    with {:ok, actor} <- actor(frame), {:ok, decision} <- operation(actor, params) do
      reply(frame, decision)
    else
      {:error, reason} -> fail(frame, "route preview refused: #{inspect(reason)}")
    end
  end

  defp actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine] and is_binary(id) and id != "", do: {:ok, actor}

  defp actor(_frame), do: {:error, :unauthenticated}

  defp operation(actor, %{request: request} = params)
       when is_map(request) and not is_map_key(params, :decision_id),
       do: RoutePreview.preview(actor, request |> Jason.encode!() |> Jason.decode!())

  defp operation(actor, %{decision_id: id} = params)
       when is_binary(id) and not is_map_key(params, :request),
       do: RoutePreview.read(actor, id)

  defp operation(_actor, _params), do: {:error, :request_or_decision_required}
end
