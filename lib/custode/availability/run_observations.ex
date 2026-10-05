defmodule Custode.Availability.RunObservations do
  @moduledoc """
  Cache provider-reported quota evidence carried by ordinary Claude runs.

  ObanClaude correlates the typed observations to its invocation and carries
  them on stop and exception telemetry. They are not completion or acceptance
  evidence. The published observation has no event timestamp, so we age it
  from the run's start lower bound, not terminal delivery. No event never
  becomes zero usage, and a newer cache entry always wins.
  """

  alias ClaudeWrapper.RateLimitObservation
  alias Custode.Availability
  alias Custode.Availability.Collectors.Claude

  @doc "Consume released Claude run metadata independently of spend attribution."
  @spec observe(map(), map(), keyword()) :: :ok
  def observe(measurements, metadata, options \\ [])

  def observe(%{duration: duration}, %{rate_limit_observations: observations}, options)
      when is_integer(duration) and duration >= 0 and is_list(observations) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    elapsed = System.convert_time_unit(duration, :native, :microsecond)
    # Round toward the older boundary rather than freshening an early frame.
    observed_at = DateTime.add(now, -(elapsed + 1), :microsecond)

    snapshot =
      observations
      |> Enum.reverse()
      |> Enum.find_value(&snapshot(&1, observed_at))

    if snapshot && Availability.put_if_newer(snapshot) == :stored do
      Custode.PubSubBridge.broadcast({:usage_changed, "claude"})
    end

    :ok
  rescue
    _error -> :ok
  end

  def observe(_measurements, _metadata, _options), do: :ok

  defp snapshot(%RateLimitObservation{source: :rate_limit_event} = observation, observed_at) do
    payload = %{
      "status" => observation.status,
      "rateLimitType" => observation.rate_limit_type,
      "unifiedWindows" => observation.unified_windows
    }

    with {:ok, snapshot} <- Claude.observe(payload, now: observed_at, cache: false),
         true <- Enum.any?(snapshot.buckets, &usable?/1) do
      %{snapshot | extra: Map.put(snapshot.extra, "timestamp_basis", "run_start_lower_bound")}
    else
      _unusable -> nil
    end
  rescue
    _malformed -> nil
  end

  defp snapshot(_other, _observed_at), do: nil

  defp usable?(bucket) do
    measured? =
      is_number(bucket.utilization) and bucket.utilization >= 0 and bucket.utilization <= 1

    measured? or bucket.status in [:rejected, :warning]
  end
end
