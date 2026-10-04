defmodule Custode.MCP.OwnerReviewTools.Review do
  @moduledoc "Submit, inspect, reconcile or cancel two durable evidence-only reviews. Results never approve work."
  use Custode.MCP.Tool, name: "owner_review"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  input_schema(%{
    "type" => "object",
    "required" => ["action"],
    "properties" => %{
      "action" => %{"type" => "string", "enum" => ~w(submit inspect cancel reconcile)},
      "review_id" => %{"type" => "string"},
      "request" => %{
        "type" => "object",
        "required" => ~w(request_id owner_id evidence routes limits),
        "properties" => %{
          "request_id" => %{"type" => "string", "maxLength" => 160},
          "owner_id" => %{"type" => "string", "maxLength" => 160},
          "evidence" => %{"type" => "string", "maxLength" => 100_000},
          "routes" => %{
            "type" => "array",
            "minItems" => 2,
            "maxItems" => 2,
            "items" => %{
              "type" => "object",
              "required" => ~w(provider model effort),
              "properties" => %{
                "provider" => %{"type" => "string"},
                "model" => %{"type" => "string"},
                "effort" => %{"type" => "string"}
              }
            }
          },
          "limits" => %{
            "type" => "object",
            "required" => ~w(calls usd time_ms),
            "properties" => %{
              "calls" => %{
                "type" => "integer",
                "description" => "Exactly two native review invocations; not provider API calls."
              },
              "usd" => %{
                "type" => "number",
                "description" =>
                  "Split evenly across native CLI budget stops; not a billing guarantee."
              },
              "time_ms" => %{"type" => "integer"},
              "tokens" => %{
                "type" => "integer",
                "description" => "Unsupported hard cap; a request naming this is refused."
              }
            }
          }
        }
      }
    }
  })

  @impl true
  def execute(params, frame) do
    with {:ok, actor} <- actor(frame), {:ok, result} <- operation(actor, params) do
      reply(frame, result)
    else
      {:error, reason} -> fail(frame, "owner review refused: #{inspect(reason)}")
    end
  end

  defp actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine] and is_binary(id) and id != "", do: {:ok, actor}

  defp actor(_frame), do: {:error, :unauthenticated}

  defp operation(actor, %{action: "submit", request: request} = params)
       when not is_map_key(params, :review_id),
       do: Custode.OwnerReviews.submit(actor, request |> Jason.encode!() |> Jason.decode!())

  defp operation(actor, %{action: "inspect", review_id: id} = params)
       when not is_map_key(params, :request), do: Custode.OwnerReviews.read(actor, id)

  defp operation(actor, %{action: "cancel", review_id: id} = params)
       when not is_map_key(params, :request), do: Custode.OwnerReviews.cancel(actor, id)

  defp operation(actor, %{action: "reconcile", review_id: id} = params)
       when not is_map_key(params, :request), do: Custode.OwnerReviews.reconcile(actor, id)

  defp operation(_actor, _params), do: {:error, :action_arguments_required}
end
