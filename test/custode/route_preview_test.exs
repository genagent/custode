defmodule Custode.RoutePreviewTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.Advisors.Model
  alias Custode.{Availability, Repo, RoutePreview}
  alias Custode.Availability.{Bucket, Snapshot}
  @actor %{kind: :operator, id: "router"}

  setup do
    first =
      routine_fixture!(tmp_workspace!(), %{
        provider: :claude,
        model: "opus",
        effort: "high",
        max_turns: 5,
        max_budget_usd: 1.0
      })

    second =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        model: "fixture-sol",
        effort: "xhigh",
        max_turns: 5,
        max_budget_usd: 1.0
      })

    put_env!(:routines, [first, second])

    put_env!(:routing_preview_policy, %{
      version: "fixture:v1",
      max_age_seconds: 60,
      interactive_reserve: 0.1,
      floors: %{"implementation" => 3, "review" => 2},
      triples: %{
        "claude/opus/high" => %{tier: 3, weight: 1.0, capabilities: ["review"]},
        "codex/fixture-sol/xhigh" => %{tier: 3, weight: 1.0, capabilities: ["review"]}
      }
    })

    saved = Map.new(~w(claude codex), &{&1, Availability.current(&1)})

    on_exit(fn ->
      for provider <- ~w(claude codex) do
        Availability.forget(provider)
        if saved[provider], do: Availability.put(saved[provider])
      end

      Repo.delete_all(RoutePreview.Decision)
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    observe("claude", 0.2, now)
    observe("codex", 0.2, now)

    request = %{
      "request_id" => uid("preview"),
      "task_id" => "fixture-task",
      "input_revision" => "pinned-input",
      "class" => "review",
      "phase" => "verify",
      "candidate_ids" => [first.id, second.id],
      "required_tools" => [],
      "required_capabilities" => ["review"],
      "isolation" => "any",
      "context_refs" => ["git:fixture@pinned"],
      "limits" => %{"calls" => 2, "usd" => 0.5, "time_ms" => 1_000}
    }

    %{first: first, second: second, request: request, now: now}
  end

  test "fresh pressure ranks exact routes with a stable tie and frozen limits", ctx do
    assert {:ok, decision} = preview(ctx)
    assert decision["status"] == "selected"
    assert decision["selected"]["id"] == Enum.min([ctx.first.id, ctx.second.id])
    assert decision["selected"]["effective_limits"] == ctx.request["limits"]
    refute decision["capacity_reserved"]
    refute decision["execution_changed"]
    assert {:ok, same} = RoutePreview.read(@actor, ctx.request["request_id"])
    assert same == decision
    observe("codex", 0.01, ctx.now)
    assert {:ok, same} = preview(ctx)
    assert same == decision
    assert {:error, :idempotency_conflict} = preview(ctx, %{"input_revision" => "changed"})
  end

  test "pins are exact and unsupported efforts never substitute", ctx do
    assert {:ok, decision} =
             preview(ctx, %{"pin" => %{"id" => ctx.second.id, "effort" => "xhigh"}})

    assert decision["selected"]["id"] == ctx.second.id

    assert {:ok, unsupported} =
             preview(ctx, %{
               "request_id" => uid("unsupported"),
               "pin" => %{"provider" => "codex", "effort" => "high"}
             })

    assert unsupported["status"] == "unsupported_pin"
    assert unsupported["selected"] == nil
  end

  test "isolation, capability, tools and native context are hard filters", ctx do
    assert {:ok, isolated} = preview(ctx, %{"isolation" => "read_only"})
    assert isolated["selected"]["id"] == ctx.second.id
    assert "isolation_unavailable" in reasons(isolated, ctx.first.id)

    assert {:ok, context} =
             preview(ctx, %{"request_id" => uid("native"), "context_provider" => "claude"})

    assert context["selected"]["id"] == ctx.first.id

    for requirement <- [
          %{"required_tools" => ["mcp__custode__not_granted"]},
          %{"required_capabilities" => ["admin"]}
        ] do
      assert {:ok, refused} = preview(ctx, Map.put(requirement, "request_id", uid("constraint")))
      assert refused["selected"] == nil
    end
  end

  test "unknown, stale and future observations are never free capacity", ctx do
    Availability.forget("claude")
    observe("codex", 0.0, DateTime.add(ctx.now, -61, :second))
    assert {:ok, deferred} = preview(ctx)
    assert deferred["status"] == "deferred"
    assert "capacity_unknown_or_stale" in reasons(deferred, ctx.first.id)
    assert "capacity_unknown_or_stale" in reasons(deferred, ctx.second.id)
    observe("codex", 0.0, DateTime.add(ctx.now, 60, :second))
    assert {:ok, future} = preview(ctx, %{"request_id" => uid("future")})
    assert future["selected"] == nil
  end

  test "rejection remains a hard constraint even with apparently spare quota", ctx do
    observe("claude", 0.0, ctx.now, :rejected)
    observe("codex", 0.95, ctx.now)
    assert {:ok, deferred} = preview(ctx)
    assert deferred["selected"] == nil
    assert "provider_rejected" in reasons(deferred, ctx.first.id)
    assert "capacity_exhausted" in reasons(deferred, ctx.second.id)
  end

  test "floors precede pressure and unknown classes retain only the configured specialist", ctx do
    policy = Application.fetch_env!(:custode, :routing_preview_policy)

    put_env!(
      :routing_preview_policy,
      put_in(policy, [:triples, "codex/fixture-sol/xhigh", :tier], 1)
    )

    observe("codex", 0.0, ctx.now)
    assert {:ok, floor} = preview(ctx)
    assert floor["selected"]["id"] == ctx.first.id
    assert "below_quality_floor" in reasons(floor, ctx.second.id)

    assert {:ok, configured} =
             preview(ctx, %{
               "request_id" => uid("unknown"),
               "class" => "unclassified",
               "configured_route" => ctx.first.id
             })

    assert configured["selected"]["id"] == ctx.first.id

    assert {:ok, unknown} =
             preview(ctx, %{"request_id" => uid("unknown"), "class" => "unclassified"})

    assert unknown["selected"] == nil
  end

  test "authority, invalid requests and unknown candidates are explicit", ctx do
    assert {:error, _reason} =
             RoutePreview.preview(%{kind: :sub_agent, id: "helper"}, ctx.request)

    assert {:error, :invalid_request} = preview(ctx, %{"limits" => %{"usd" => 1}})
    assert {:ok, unknown} = preview(ctx, %{"candidate_ids" => ["absent"]})

    assert unknown["alternatives"] == [
             %{
               "id" => "absent",
               "score" => nil,
               "reasons" => ["unknown_or_transitioning_candidate"]
             }
           ]

    assert Repo.aggregate(from(d in RoutePreview.Decision, where: d.actor_id == "router"), :count) ==
             1
  end

  test "retired recommendations stay out of standing suggestions without erasing history", _ctx do
    id = uid("retired-model")

    Custode.Feed.record(%{
      event: "advisor_suggestion",
      advisor: "model",
      agent: id,
      field: "model",
      proposed: "sonnet",
      summary: "old unattributed advice"
    })

    refute Enum.any?(Custode.Suggestions.standing(), &(&1["agent"] == id))

    assert Enum.any?(
             Custode.Feed.recent_by_event("advisor_suggestion", limit: 100),
             &(&1["agent"] == id)
           )

    assert Model.suggest([
             %{provider: :claude, model: "opus", sweeps: 30, yields: 0}
           ]) == []
  end

  defp preview(ctx, patch \\ %{}),
    do: RoutePreview.preview(@actor, Map.merge(ctx.request, patch), now: ctx.now)

  defp reasons(decision, id),
    do: Enum.find(decision["alternatives"], &(&1["id"] == id))["reasons"]

  defp observe(provider, utilization, now, status \\ :ok),
    do:
      Availability.put(%Snapshot{
        provider: provider,
        source: "fixture-not-natural",
        observed_at: now,
        buckets: [
          %Bucket{
            id: "window",
            status: status,
            utilization: utilization,
            resets_at: DateTime.add(now, 3600, :second)
          }
        ]
      })
end
