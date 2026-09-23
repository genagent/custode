defmodule Custode.UsageTest do
  # the availability store is one ETS table
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ExUnit.CaptureLog

  alias Custode.Availability
  alias Custode.Availability.ClaudeOAuthUsage
  alias Custode.Availability.Collectors.Claude
  alias Custode.Availability.Probe

  @now ~U[2026-09-20 03:50:00.000000Z]

  # captured verbatim from `claude` 2.1.273 on a Max plan, 2026-09-19 (#458)
  @event %{
    "type" => "rate_limit_event",
    "rate_limit_info" => %{
      "status" => "allowed",
      "resetsAt" => 1_789_892_400,
      "rateLimitType" => "five_hour",
      "overageStatus" => "rejected",
      "overageDisabledReason" => "out_of_credits",
      "isUsingOverage" => false,
      "unifiedWindows" => %{
        "five_hour" => %{"utilization" => 0.12, "resetsAt" => 1_789_892_400},
        "seven_day" => %{"utilization" => 0.41, "resetsAt" => 1_790_218_800}
      }
    }
  }

  setup do
    Availability.forget(:all)
    put_env!(:usage_oauth_fun, fn _options -> {:error, :credential_not_found} end)
    on_exit(fn -> Availability.forget(:all) end)
    :ok
  end

  describe "the collector reads a real event" do
    test "both windows, as fractions, with unix resets, the wrapper unwrapped" do
      {:ok, snapshot} = Claude.observe(@event, now: @now)

      buckets = Map.new(snapshot.buckets, &{&1.id, &1})
      assert buckets["five_hour"].utilization == 0.12
      assert buckets["seven_day"].utilization == 0.41
      assert buckets["five_hour"].resets_at == DateTime.from_unix!(1_789_892_400)
      assert buckets["seven_day"].resets_at == DateTime.from_unix!(1_790_218_800)
      assert buckets["five_hour"].status == :ok
      assert buckets["seven_day"].status == :ok
    end

    test "the event's one status belongs to the window it names, not to all of them" do
      rejected =
        @event
        |> put_in(["rate_limit_info", "status"], "rejected")
        |> put_in(["rate_limit_info", "rateLimitType"], "seven_day")

      {:ok, snapshot} = Claude.observe(rejected, now: @now)
      buckets = Map.new(snapshot.buckets, &{&1.id, &1})

      assert buckets["seven_day"].status == :rejected
      assert buckets["five_hour"].status == :ok
    end
  end

  describe "OAuth usage" do
    @oauth_usage %{
      "five_hour" => %{"utilization" => 12.0, "resets_at" => "2026-09-20T05:00:00Z"},
      "seven_day" => %{"utilization" => 41.0, "resets_at" => "2026-09-24T05:00:00Z"},
      "seven_day_sonnet" => %{
        "utilization" => 1.0,
        "resets_at" => "2026-09-24T06:00:00Z"
      },
      "extra_usage" => %{"utilization" => 70.0}
    }

    test "normalizes endpoint percentages, including exactly one percent" do
      assert {:ok, snapshot} = Claude.observe_oauth_usage(@oauth_usage, now: @now)
      buckets = Map.new(snapshot.buckets, &{&1.id, &1})

      assert snapshot.source == "oauth_usage_endpoint"
      assert buckets["five_hour"].utilization == 0.12
      assert buckets["seven_day"].utilization == 0.41
      assert buckets["seven_day_sonnet"].utilization == 0.01
      assert buckets["five_hour"].window_seconds == 18_000
      assert buckets["seven_day_sonnet"].window_seconds == 604_800
      refute Map.has_key?(buckets, "extra_usage")
    end

    test "rejects a successful response with no usage windows" do
      assert Claude.observe_oauth_usage(%{"extra_usage" => %{}}, now: @now) ==
               {:error, :unexpected_oauth_usage_payload}

      assert Availability.usage("claude", now: @now).freshness == :unknown
    end

    test "reads nested and flat credential shapes without retaining refresh tokens" do
      nested =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "secret-access",
            "refreshToken" => "secret-refresh",
            "expiresAt" => 1_800_000_000_000,
            "subscriptionType" => "max"
          }
        })

      assert {:ok, credential} = ClaudeOAuthUsage.parse_credential(nested)
      assert credential.access_token == "secret-access"
      assert credential.expires_at_ms == 1_800_000_000_000
      assert credential.subscription_type == "max"
      refute Map.has_key?(credential, :refresh_token)

      assert {:ok, %{access_token: "flat"}} =
               ClaudeOAuthUsage.parse_credential(~s({"accessToken":"flat"}))
    end

    test "reads the default macOS keychain item without exposing its output" do
      test_pid = self()
      raw = Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "keychain-token"}})

      command_fun = fn command, args, _options ->
        send(test_pid, {:command, command, args})
        {raw, 0}
      end

      assert {:ok, %{access_token: "keychain-token"}} =
               ClaudeOAuthUsage.read_credential(
                 platform: :darwin,
                 config_dir: Path.join(System.user_home!(), ".claude"),
                 user: "operator",
                 command_fun: command_fun
               )

      assert_receive {:command, "security", args}

      assert args == [
               "find-generic-password",
               "-s",
               "Claude Code-credentials",
               "-a",
               "operator",
               "-w"
             ]
    end

    test "uses the credentials file outside macOS" do
      test_pid = self()
      raw = Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "file-token"}})

      read_fun = fn path ->
        send(test_pid, {:read, path})
        {:ok, raw}
      end

      assert {:ok, %{access_token: "file-token"}} =
               ClaudeOAuthUsage.read_credential(
                 platform: :linux,
                 config_dir: "/tmp/claude-profile",
                 read_fun: read_fun
               )

      assert_receive {:read, "/tmp/claude-profile/.credentials.json"}
    end

    test "scopes a custom macOS config directory to its hashed keychain item" do
      test_pid = self()
      config_dir = "/tmp/claude-work"
      raw = Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "work-token"}})

      command_fun = fn _command, args, _options ->
        send(test_pid, {:args, args})
        {raw, 0}
      end

      assert {:ok, %{access_token: "work-token"}} =
               ClaudeOAuthUsage.read_credential(
                 platform: :darwin,
                 config_dir: config_dir,
                 user: "operator",
                 command_fun: command_fun
               )

      expected_service = ClaudeOAuthUsage.keychain_service(config_dir)
      assert_receive {:args, ["find-generic-password", "-s", ^expected_service | _rest]}
      refute expected_service == "Claude Code-credentials"
    end

    test "sends the token only to the bounded usage request and caches no token" do
      test_pid = self()

      credential_fun = fn _options ->
        {:ok, %{access_token: "one-request-secret", expires_at_ms: nil, subscription_type: "max"}}
      end

      http_fun = fn url, options ->
        send(test_pid, {:request, url, options})
        {:ok, %Req.Response{status: 200, body: @oauth_usage}}
      end

      assert {:ok, snapshot} =
               ClaudeOAuthUsage.collect(
                 now: @now,
                 credential_fun: credential_fun,
                 http_fun: http_fun
               )

      assert_receive {:request, "https://api.anthropic.com/api/oauth/usage", options}
      assert {"authorization", "Bearer one-request-secret"} in options[:headers]
      assert {"anthropic-beta", "oauth-2025-04-20"} in options[:headers]
      refute inspect(snapshot) =~ "one-request-secret"
      refute inspect(Availability.current("claude")) =~ "one-request-secret"
    end

    test "sanitizes endpoint failures" do
      credential_fun = fn _options ->
        {:ok, %{access_token: "never-log-this", expires_at_ms: nil, subscription_type: nil}}
      end

      http_fun = fn _url, _options ->
        {:ok, %Req.Response{status: 500, body: %{"echo" => "never-log-this"}}}
      end

      result = ClaudeOAuthUsage.collect(credential_fun: credential_fun, http_fun: http_fun)
      assert result == {:error, {:http_status, 500}}
      refute inspect(result) =~ "never-log-this"
    end
  end

  describe "usage/2, what a page draws" do
    test "unknown is unknown, never zero percent" do
      assert Availability.usage("claude", now: @now) ==
               %{
                 freshness: :unknown,
                 observed_at: nil,
                 age_seconds: nil,
                 held_until: nil,
                 windows: []
               }
    end

    test "labels the windows and puts the shortest first, because it bites first" do
      {:ok, _snapshot} = Claude.observe(@event, now: @now)

      assert %{freshness: :fresh, windows: [five, seven]} =
               Availability.usage("claude", now: @now)

      assert %{label: "5h", utilization: 0.12} = five
      assert %{label: "7d", utilization: 0.41} = seven
    end

    test "an old observation is stale, and says so" do
      {:ok, _snapshot} = Claude.observe(@event, now: @now)
      later = DateTime.add(@now, 3_600, :second)

      assert Availability.usage("claude", now: later).freshness == :stale
    end
  end

  describe "the probe" do
    test "uses OAuth usage without starting a model turn" do
      test_pid = self()
      {:ok, snapshot} = Claude.observe_oauth_usage(@oauth_usage, now: @now, cache: false)

      put_env!(:usage_oauth_fun, fn _options -> {:ok, snapshot} end)
      put_env!(:usage_probe_fun, fn -> send(test_pid, :probed) end)

      assert {:ok, ^snapshot} = Probe.run(now: @now)
      refute_receive :probed
    end

    test "takes the rate_limit_event out of a run's stream and records it" do
      Custode.PubSubBridge.subscribe()

      put_env!(:usage_probe_fun, fn ->
        [
          %{type: "system", data: %{}},
          %{type: "rate_limit_event", data: @event},
          %{type: "result", data: %{"result" => "ok"}}
        ]
      end)

      assert {:ok, _snapshot} = Probe.run(now: @now)
      assert [%{label: "5h"}, %{label: "7d"}] = Availability.usage("claude", now: @now).windows
      assert_receive {:usage_changed, "claude"}
    end

    test "skips itself when the snapshot is already fresh, and runs when forced" do
      test_pid = self()
      {:ok, _snapshot} = Claude.observe(@event, now: @now)

      put_env!(:usage_probe_fun, fn ->
        send(test_pid, :probed)
        [%{type: "rate_limit_event", data: @event}]
      end)

      assert Probe.run(now: @now) == :fresh
      refute_receive :probed, 50

      assert {:ok, _snapshot} = Probe.run(now: @now, force: true)
      assert_receive :probed
    end

    # absence advises proceeding: a broken probe is an empty header, not an outage
    test "a run with no event, or a run that raises, records nothing and says so" do
      put_env!(:usage_probe_fun, fn -> [%{type: "result", data: %{}}] end)
      log = capture_log(fn -> assert Probe.run(now: @now) == {:error, :no_rate_limit_event} end)
      assert log =~ "no rate_limit_event"

      put_env!(:usage_probe_fun, fn -> raise "claude is not installed" end)
      log = capture_log(fn -> assert Probe.run(now: @now) == {:error, :probe_failed} end)
      assert log =~ "claude is not installed"

      assert Availability.usage("claude", now: @now).freshness == :unknown
    end

    test "is on the crontab by default and off when disabled" do
      put_env!(:usage_probe_cron, "*/10 * * * *")
      assert Enum.any?(Custode.Routine.crontab(), &match?({_cron, Probe, _opts}, &1))

      put_env!(:usage_probe_cron, false)
      refute Enum.any?(Custode.Routine.crontab(), &match?({_cron, Probe, _opts}, &1))
    end
  end
end
