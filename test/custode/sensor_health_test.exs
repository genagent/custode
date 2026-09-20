defmodule Custode.Sensor.HealthTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Memory
  alias Custode.Sensor.Health

  # `memories` is shared by the whole suite, so every sensor id here is unique
  # and every read of `failing/0` is scoped to it.
  setup do
    %{sensor_id: uid("health-sensor")}
  end

  describe "record_failure/2" do
    test "counts consecutive failures and keeps the latest error", %{sensor_id: sensor_id} do
      assert %{failures: 1, last_error: ":rate_limited"} =
               Health.record_failure(sensor_id, :rate_limited)

      assert %{failures: 2} = Health.record_failure(sensor_id, :rate_limited)

      assert %{failures: 3, last_error: "SAML enforcement"} =
               Health.record_failure(sensor_id, "SAML enforcement")

      assert %{failures: 3, last_error: "SAML enforcement"} = Health.get(sensor_id)
    end

    test "dates the streak from its first failure, not its latest", %{sensor_id: sensor_id} do
      %{since: first} = Health.record_failure(sensor_id, :boom)
      %{since: second} = Health.record_failure(sensor_id, :boom)

      assert %DateTime{} = first
      assert DateTime.compare(first, second) == :eq
    end

    test "lives beside the seen-set without touching it", %{sensor_id: sensor_id} do
      :ok = Memory.remember("sensor:" <> sensor_id, "seen", ~s(["a","b"]))
      Health.record_failure(sensor_id, :boom)
      Health.record_success(sensor_id)

      assert {:ok, ~s(["a","b"])} = Memory.recall("sensor:" <> sensor_id, "seen")
    end
  end

  describe "record_success/1" do
    test "one success ends the streak", %{sensor_id: sensor_id} do
      Health.record_failure(sensor_id, :boom)
      Health.record_failure(sensor_id, :boom)
      :ok = Health.record_success(sensor_id)

      assert Health.get(sensor_id) == nil
      assert %{failures: 1} = Health.record_failure(sensor_id, :boom)
    end

    test "is a no-op for a sensor that was never failing", %{sensor_id: sensor_id} do
      assert :ok = Health.record_success(sensor_id)
      assert Health.get(sensor_id) == nil
    end
  end

  describe "failing/0" do
    test "returns every sensor with a streak, keyed by sensor id", %{sensor_id: sensor_id} do
      healthy = uid("health-sensor")
      Health.record_failure(sensor_id, "renamed repo")
      Health.record_failure(healthy, :boom)
      Health.record_success(healthy)

      failing = Health.failing()
      assert %{failures: 1, last_error: "renamed repo"} = failing[sensor_id]
      refute Map.has_key?(failing, healthy)
    end

    test "a value in another shape reads as no streak rather than crashing",
         %{sensor_id: sensor_id} do
      :ok = Memory.remember("sensor:" <> sensor_id, "health", "not json")

      refute Map.has_key?(Health.failing(), sensor_id)
      assert Health.get(sensor_id) == nil
      # and the next failure starts a fresh count over it
      assert %{failures: 1} = Health.record_failure(sensor_id, :boom)
    end
  end

  describe "describe/1" do
    test "a string is kept as written, on one line and capped" do
      assert Health.describe("  Resource protected by\norganization SAML enforcement\n") ==
               "Resource protected by organization SAML enforcement"

      assert String.length(Health.describe(String.duplicate("x", 5_000))) == 300
    end

    test "anything else is inspected, and an exception gives its message" do
      assert Health.describe({:status, 503}) == "{:status, 503}"
      assert Health.describe(%RuntimeError{message: "nope"}) == "nope"
    end
  end

  describe "threshold/0" do
    test "defaults to three and follows :sensor_failure_threshold" do
      assert Health.threshold() == 3
      put_env!(:sensor_failure_threshold, 5)
      assert Health.threshold() == 5
    end
  end
end
