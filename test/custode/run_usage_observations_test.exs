defmodule Custode.RunUsageObservationsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias ClaudeWrapper.{RateLimitObservation, Result}
  alias Custode.Availability
  alias Custode.Availability.Collectors.Claude
  alias Custode.Availability.Probe
  alias Custode.Availability.RunObservations

  @now ~U[2026-10-05 12:00:00.000000Z]

  defmodule Runner do
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("expected observed one-shot execution")

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: raise("unexpected stream execution")

    @impl true
    def run_observed(_binary, _args, _opts, _timeout, observer) do
      event = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "allowed",
          "rateLimitType" => "five_hour",
          "unifiedWindows" => %{"five_hour" => %{"utilization" => 0.42}}
        }
      }

      observer.(Jason.encode!(event))

      case Process.get(:usage_fixture_outcome) do
        :timeout ->
          {:error, :timeout}

        _success ->
          result = %{
            "type" => "result",
            "subtype" => "success",
            "result" => "fixture result",
            "is_error" => false,
            "session_id" => "usage-fixture-session",
            "total_cost_usd" => 0.0
          }

          {:ok, {Jason.encode!(result), 0, ""}}
      end
    end
  end

  setup do
    Availability.forget(:all)
    on_exit(fn -> Availability.forget(:all) end)
    :ok
  end

  test "ordered observations preserve reported windows and notify without starting a probe" do
    Custode.PubSubBridge.subscribe()
    parent = self()
    put_env!(:usage_oauth_fun, fn _opts -> send(parent, :oauth_started) end)
    put_env!(:usage_probe_fun, fn -> send(parent, :probe_started) end)

    assert :ok =
             RunObservations.observe(
               %{duration: duration(3)},
               %{rate_limit_observations: [observation(0.2), observation(0.9, "rejected")]},
               now: @now
             )

    snapshot = Availability.current("claude")
    assert snapshot.source == "agent_sdk_rate_limit_event"
    assert snapshot.observed_at == DateTime.add(@now, -3_000_001, :microsecond)
    assert snapshot.extra["timestamp_basis"] == "run_start_lower_bound"
    assert [%{id: "five_hour", utilization: 0.9, status: :rejected}] = snapshot.buckets
    assert_receive {:usage_changed, "claude"}
    refute_receive {:usage_changed, "claude"}
    assert Probe.run(now: @now) == :fresh
    refute_receive :oauth_started
    refute_receive :probe_started
  end

  test "a long run remains stale and cannot replace a newer OAuth observation" do
    RunObservations.observe(
      %{duration: duration(1800)},
      %{rate_limit_observations: [observation(0.9)]},
      now: @now
    )

    assert Availability.usage("claude", now: @now).freshness == :stale

    {:ok, oauth} =
      Claude.observe_oauth_usage(%{"five_hour" => %{"utilization" => 30}}, now: @now)

    Custode.PubSubBridge.subscribe()

    RunObservations.observe(
      %{duration: duration(1)},
      %{rate_limit_observations: [observation(0.9)]},
      now: @now
    )

    assert Availability.current("claude") == oauth
    refute_receive {:usage_changed, "claude"}
  end

  test "missing raw unknown or malformed evidence never invents zero usage" do
    for metadata <- [
          %{},
          %{rate_limit_observations: []},
          %{rate_limit_observations: [%{"status" => "allowed"}]},
          %{rate_limit_observations: [%RateLimitObservation{status: "allowed"}]},
          %{rate_limit_observations: [%RateLimitObservation{status: "future_status"}]},
          %{rate_limit_observations: :malformed}
        ] do
      assert :ok = RunObservations.observe(%{duration: duration(0)}, metadata, now: @now)
      assert Availability.current("claude") == nil
    end

    for measurements <- [%{}, %{duration: -1}, %{duration: "unknown"}] do
      assert :ok =
               RunObservations.observe(
                 measurements,
                 %{rate_limit_observations: [observation(0.4)]},
                 now: @now
               )

      assert Availability.current("claude") == nil
    end

    assert Availability.usage("claude", now: @now).freshness == :unknown
  end

  test "unusable final frames leave earlier usable evidence available" do
    assert :ok =
             RunObservations.observe(
               %{duration: duration(0)},
               %{
                 rate_limit_observations: [
                   observation(0.5),
                   %RateLimitObservation{status: "allowed"},
                   %RateLimitObservation{
                     status: "allowed",
                     unified_windows: %{{:invalid, :key} => %{"utilization" => 0.1}}
                   },
                   %{untrusted: "raw frame"}
                 ]
               },
               now: @now
             )

    assert [%{utilization: 0.5}] = Availability.current("claude").buckets
  end

  test "successful and failed Claude telemetry collect independently of spend attribution" do
    for outcome <- [:stop, :exception] do
      Availability.forget(:all)

      :telemetry.execute(
        [:oban_claude, :run, outcome],
        %{cost_usd: 0.0, duration: duration(0)},
        %{job: nil, rate_limit_observations: [observation(0.4)]}
      )

      assert [%{utilization: 0.4}] = Availability.current("claude").buckets
    end

    Availability.forget(:all)

    :telemetry.execute(
      [:oban_codex, :run, :stop],
      %{cost_usd: 0.0, duration: duration(0)},
      %{job: nil, rate_limit_observations: [observation(0.4)]}
    )

    assert Availability.current("claude") == nil
  end

  test "malformed usage evidence cannot interfere with correlated spend recording" do
    id = uid("run-usage-spender")

    :telemetry.execute(
      [:oban_claude, :run, :stop],
      %{cost_usd: 0.12, duration: duration(0)},
      %{
        job: %{meta: %{"agent_id" => id}},
        rate_limit_observations: :malformed
      }
    )

    assert_in_delta Custode.SpendLedger.today(id), 0.12, 0.0001
    assert Availability.current("claude") == nil
  end

  test "the published default Oban query forwards observed evidence on success and timeout" do
    previous = Application.fetch_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, Runner)

    on_exit(fn ->
      case previous do
        {:ok, runner} -> Application.put_env(:claude_wrapper, :runner, runner)
        :error -> Application.delete_env(:claude_wrapper, :runner)
      end
    end)

    assert {:ok, %Result{result: "fixture result"}} = ObanClaude.run(%{"prompt" => "fixture"})
    assert [%{utilization: 0.42}] = Availability.current("claude").buckets

    Availability.forget(:all)
    Process.put(:usage_fixture_outcome, :timeout)

    assert {{:error, :timeout}, %ClaudeWrapper.Error{kind: :timeout}} =
             ObanClaude.run(%{"prompt" => "fixture"})

    assert [%{utilization: 0.42}] = Availability.current("claude").buckets
  end

  test "concurrent run cache writers retain the newest observation" do
    {:ok, baseline} =
      Claude.observe(
        %{"status" => "allowed", "unifiedWindows" => %{"five_hour" => %{"utilization" => 0.2}}},
        now: @now,
        cache: false
      )

    results =
      1..50
      |> Task.async_stream(fn seconds ->
        Availability.put_if_newer(%{baseline | observed_at: DateTime.add(@now, seconds)})
      end)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, result} when result in [:stored, :older], &1))
    assert Availability.current("claude").observed_at == DateTime.add(@now, 50)
    assert :older = Availability.put_if_newer(baseline)
    assert Availability.current("claude").observed_at == DateTime.add(@now, 50)
  end

  defp observation(utilization, status \\ "allowed") do
    %RateLimitObservation{
      status: status,
      rate_limit_type: "five_hour",
      unified_windows: %{"five_hour" => %{"utilization" => utilization}}
    }
  end

  defp duration(seconds), do: System.convert_time_unit(seconds, :second, :native)
end
