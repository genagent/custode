defmodule Custode.Availability.Parse do
  @moduledoc """
  Tolerant normalization of whatever a provider reported (#393).

  Providers disagree about names, units and even shape, and they change all
  three without asking. So this reads by MEANING and keeps everything it did
  not recognize.

  Two rules do most of the work:

    * a field that is absent stays `nil`, never `0`. "Not reported" and "none
      used" are different facts and only one of them is safe to act on;
    * anything unrecognized lands in `extra`, so a provider adding a field
      makes it visible to whoever is debugging a deferral without waiting for
      a release that teaches core policy the new name.
  """

  alias Custode.Availability.Bucket

  @known ~w(
    id name key status state used_percent utilization used usage percent
    window_minutes window_seconds window resets_at reset_at resets_in_seconds
    limit_type type
  )

  @doc "One provider bucket payload as a typed Bucket."
  @spec bucket(String.t(), map(), DateTime.t()) :: Bucket.t()
  def bucket(id, payload, now) when is_map(payload) do
    %Bucket{
      id: to_string(value(payload, ["id", "name", "key"]) || id),
      status: status(value(payload, ["status", "state"])),
      window_seconds: window_seconds(payload),
      limit_type: value(payload, ["limit_type", "type"]),
      utilization: utilization(payload),
      resets_at: resets_at(payload, now),
      extra: unknown(payload)
    }
  end

  @doc """
  A reported status, defaulting to `:unknown` rather than `:ok`.

  An unrecognized status string is not evidence of health.
  """
  @spec status(term()) :: Bucket.status()
  def status(value) when is_binary(value) do
    cond do
      value in ~w(rejected rejecting exhausted limited over_limit) -> :rejected
      value in ~w(warning allowed_warning near_limit approaching) -> :warning
      value in ~w(ok allowed available healthy fine) -> :ok
      true -> :unknown
    end
  end

  def status(_value), do: :unknown

  @doc """
  Utilization as a 0..1 fraction, or nil.

  Percentages arrive as 0..100 and fractions as 0..1, and nothing marks
  which. A value above 1 is read as a percentage, which is the only reading
  that cannot silently understate pressure.
  """
  @spec utilization(map()) :: float() | nil
  def utilization(payload) do
    case value(payload, ["used_percent", "utilization", "percent", "used", "usage"]) do
      value when is_number(value) and value > 1 -> value / 100
      value when is_number(value) -> value * 1.0
      _absent -> nil
    end
  end

  @doc "The reported window in seconds, or nil."
  @spec window_seconds(map()) :: pos_integer() | nil
  def window_seconds(payload) do
    cond do
      is_number(value(payload, ["window_seconds"])) ->
        trunc(value(payload, ["window_seconds"]))

      is_number(value(payload, ["window_minutes"])) ->
        trunc(value(payload, ["window_minutes"]) * 60)

      is_number(value(payload, ["window"])) ->
        trunc(value(payload, ["window"]) * 60)

      true ->
        nil
    end
  end

  @doc "The reset instant, from an absolute timestamp or a relative offset."
  @spec resets_at(map(), DateTime.t()) :: DateTime.t() | nil
  def resets_at(payload, now) do
    case value(payload, ["resets_at", "resetsAt", "reset_at", "resets_in_seconds"]) do
      value when is_binary(value) -> from_iso(value)
      value when is_integer(value) and value > 1_000_000_000 -> from_unix(value)
      value when is_number(value) -> DateTime.add(now, trunc(value), :second)
      _absent -> nil
    end
  end

  @doc "Every field this shape did not recognize, kept as evidence."
  @spec unknown(map()) :: map()
  def unknown(payload) do
    payload
    |> Enum.reject(fn {key, _value} -> to_string(key) in @known end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  @doc "Read the first present key from a list of aliases."
  @spec value(map(), [String.t()]) :: term()
  def value(payload, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(payload, key) || Map.get(payload, safe_atom(key))
    end)
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp from_iso(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp from_unix(value) do
    case DateTime.from_unix(value) do
      {:ok, at} -> at
      _error -> nil
    end
  end
end

defmodule Custode.Availability.Collectors.Claude do
  @moduledoc """
  Claude availability from Agent SDK rate-limit events and OAuth usage (#393,
  #524).

  Ordinary observed runs can supply provider-reported rate-limit events;
  the separate OAuth usage adapter provides a preflight source without a
  model call. The optional probe retains a sealed fallback when that source
  is unavailable. The interactive usage screen is not scraped.

  When no source has supplied usable evidence, `Custode.Availability`
  reports `unknown` rather than headroom. Run observations use a conservative
  run-start age bound because the released event has no individual timestamp.
  """

  alias Custode.Availability
  alias Custode.Availability.{Parse, Snapshot}

  @provider "claude"

  @doc "Record one Agent SDK rate-limit event as an observation."
  @spec observe(map(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def observe(event, options \\ [])

  def observe(event, options) when is_map(event) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    # The CLI wraps the payload: `{"type": "rate_limit_event",
    # "rate_limit_info": {...}}` (captured from claude 2.1.273, #458). A bare
    # payload, which is what this was first written against, still works.
    event = Parse.value(event, ["rate_limit_info"]) || event

    snapshot = %Snapshot{
      provider: @provider,
      source: "agent_sdk_rate_limit_event",
      account_scope: Parse.value(event, ["account", "organization_id", "account_scope"]),
      observed_at: now,
      buckets: buckets(event, now),
      extra: Parse.unknown(event)
    }

    if Keyword.get(options, :cache, true), do: Availability.put(snapshot)
    {:ok, snapshot}
  end

  def observe(_event, _options), do: {:error, :invalid_rate_limit_event}

  @doc "Record one response from Claude's OAuth usage endpoint."
  @spec observe_oauth_usage(map(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def observe_oauth_usage(payload, options \\ [])

  def observe_oauth_usage(payload, options) when is_map(payload) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    buckets = oauth_buckets(payload, now)

    if buckets == [] do
      {:error, :unexpected_oauth_usage_payload}
    else
      snapshot = %Snapshot{
        provider: @provider,
        source: "oauth_usage_endpoint",
        account_scope: Keyword.get(options, :account_scope),
        observed_at: now,
        buckets: buckets,
        extra: Parse.unknown(payload)
      }

      if Keyword.get(options, :cache, true), do: Availability.put(snapshot)
      {:ok, snapshot}
    end
  end

  def observe_oauth_usage(_payload, _options), do: {:error, :unexpected_oauth_usage_payload}

  # An event may carry named windows or describe a single unified limit.
  # `unifiedWindows` is what a Max plan sends: one entry per window
  # (`five_hour`, `seven_day`), each with a utilization and a reset, and ONE
  # status for the whole event that belongs to the window named by
  # `rateLimitType`.
  defp buckets(event, now) do
    case Parse.value(event, ["unifiedWindows", "rate_limits", "limits", "windows"]) do
      limits when is_map(limits) and map_size(limits) > 0 ->
        binding = to_string(Parse.value(event, ["rateLimitType", "limit_type"]) || "")
        status = Parse.value(event, ["status", "unified_status"])

        for {id, payload} <- limits, is_map(payload) do
          payload = window_status(payload, to_string(id) == binding, status)
          Parse.bucket(to_string(id), payload, now)
        end

      _absent ->
        [Parse.bucket("unified", unified(event), now)]
    end
  end

  # A window with its own status keeps it. Otherwise the event's status is the
  # binding window's, and any other window that reported a utilization is ok:
  # it was measured and it is not the one the provider is complaining about.
  defp window_status(%{"status" => _own} = payload, _binding?, _status), do: payload

  defp window_status(payload, true, status) when is_binary(status),
    do: Map.put(payload, "status", status)

  defp window_status(payload, _binding?, _status) do
    if is_number(Parse.utilization(payload)), do: Map.put(payload, "status", "ok"), else: payload
  end

  defp unified(event) do
    %{
      "status" => Parse.value(event, ["unified_status", "status"]),
      "resets_at" => Parse.value(event, ["unified_reset_at", "resets_at", "reset_at"]),
      "utilization" => Parse.value(event, ["utilization", "used_percent"])
    }
  end

  defp oauth_buckets(payload, now) do
    payload
    |> Enum.filter(fn {id, value} -> oauth_window?(to_string(id), value) end)
    |> Enum.sort_by(fn {id, _value} -> to_string(id) end)
    |> Enum.map(fn {id, value} -> oauth_bucket(to_string(id), value, now) end)
  end

  defp oauth_window?(id, value) when is_map(value) do
    (id == "five_hour" or String.starts_with?(id, "seven_day")) and
      is_number(Parse.value(value, ["utilization"]))
  end

  defp oauth_window?(_id, _value), do: false

  # The OAuth endpoint documents utilization as a percentage. Normalize it
  # before the generic parser, where exactly `1` is otherwise ambiguous.
  defp oauth_bucket(id, value, now) do
    utilization = Parse.value(value, ["utilization"]) / 100

    value
    |> Map.put("utilization", utilization |> max(0.0) |> min(1.0))
    |> Map.put("status", "ok")
    |> Map.put("window_seconds", oauth_window_seconds(id))
    |> then(&Parse.bucket(id, &1, now))
  end

  defp oauth_window_seconds("five_hour"), do: 5 * 60 * 60
  defp oauth_window_seconds("seven_day" <> _scope), do: 7 * 24 * 60 * 60
end

defmodule Custode.Availability.Collectors.Codex do
  @moduledoc """
  Codex availability from a preflight quota read (#393).

  Codex exposes `account/rateLimits/read` through `codex app-server`, so
  unlike Claude it CAN be asked before any Attempt starts. That is the whole
  value: the check costs nothing and happens before the expensive decision.

  ## Configured, not assumed

  The command is `:codex_availability_command` and there is no default. The
  invocation depends on the local Codex install and its authenticated
  session, and shelling out to an unverified command on a running fleet is
  not a reasonable default. Unconfigured reports `unknown`, which every
  caller already handles.

  The reader is read-only and never persists credentials or authentication
  material; it consumes the payload and keeps quota fields only.
  """

  alias Custode.Availability
  alias Custode.Availability.{Parse, Snapshot}

  @provider "codex"

  @doc """
  Read current Codex quota without starting an Attempt.

  Pass `:read_fun` to supply the payload directly; otherwise the configured
  command is run and its stdout parsed as JSON.
  """
  @spec collect(keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def collect(options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    with {:ok, payload} <- read(options) do
      snapshot = %Snapshot{
        provider: @provider,
        source: "app_server_rate_limits_read",
        account_scope: Parse.value(payload, ["account_id", "plan", "account_scope"]),
        observed_at: now,
        buckets: buckets(payload, now),
        extra: Parse.unknown(payload)
      }

      if Keyword.get(options, :cache, true), do: Availability.put(snapshot)
      {:ok, snapshot}
    end
  end

  @doc "Parse a rate-limits payload without running anything."
  @spec from_payload(map(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def from_payload(payload, options \\ []) when is_map(payload),
    do: collect(Keyword.put(options, :read_fun, fn -> {:ok, payload} end))

  defp read(options) do
    case Keyword.get(options, :read_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> run_configured_command()
    end
  end

  defp run_configured_command do
    case Application.get_env(:custode, :codex_availability_command) do
      [command | args] when is_binary(command) -> run(command, args)
      _unset -> {:error, :collector_not_configured}
    end
  end

  defp run(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> decode(output)
      {output, status} -> {:error, {:collector_failed, status, String.slice(output, 0, 200)}}
    end
  rescue
    error -> {:error, {:collector_failed, Exception.message(error)}}
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _other} -> {:error, :unexpected_rate_limit_payload}
      {:error, _reason} -> {:error, :unparsable_rate_limit_payload}
    end
  end

  # Bucket names are the provider's, and stay opaque. `primary` is an id, not
  # a meaning, so nothing here treats it as "the five-hour window".
  defp buckets(payload, now) do
    case Parse.value(payload, ["rate_limits", "rateLimits", "limits"]) do
      limits when is_map(limits) ->
        limits
        |> Enum.filter(fn {_id, value} -> is_map(value) end)
        |> Enum.sort_by(fn {id, _value} -> to_string(id) end)
        |> Enum.map(fn {id, value} -> Parse.bucket(to_string(id), value, now) end)

      limits when is_list(limits) ->
        for value <- limits, is_map(value), do: Parse.bucket("bucket", value, now)

      _absent ->
        []
    end
  end
end
