defmodule Custode.Sensor.Health do
  @moduledoc """
  Whether a sensor's fetch is working, remembered between runs (#444).

  ## Why this exists

  A sensor is `max_attempts: 1` and, until #444, kept no memory of how its
  previous run went. A failed fetch fed one grey `sensor` line and the next
  run started from nothing, so "failing every time" was not a state the
  system could see. Observed on the live fleet: `ci-redisctl` failed every
  run since at least 2026-09-14 with `Resource protected by organization SAML
  enforcement`, drawn identically to the twelve healthy CI sensors beside it.
  A detection channel was dark and looked quiet.

  ## The shape

  One `health` memory beside the seen-set, under the sensor's existing
  `"sensor:" <> sensor_id` scope, holding the consecutive-failure count, the
  last error and when the streak began. No table and no migration: the
  storage doctrine already gives a sensor a scope that persists between runs,
  and this is three fields in it.

  One success forgets the memory. The count means CONSECUTIVE, so a sensor
  that fails one run in ten never accumulates toward the threshold.

  ## What is a fact and what is a decision

  This module records and reads. Whether a count is high enough to tell the
  operator is `Custode.Attention`'s call, made against `threshold/0`, which
  `Custode.Attention.Fleet` hands it in the context. The threshold lives here
  only because `Custode.Sensor` also needs it, to mark the one feed entry
  that crosses it.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Memory
  alias Custode.Repo

  @scope "sensor:"
  @key "health"
  @default_threshold 3

  # An error is evidence for a headline, not a transcript: a failed `gh` call
  # hands back everything it printed.
  @error_cap 300

  @type t :: %{failures: pos_integer(), last_error: String.t(), since: DateTime.t() | nil}

  @doc """
  How many consecutive failed runs make a sensor worth a signal.

  `config :custode, sensor_failure_threshold: 3`. Three, because one failure
  is a network blip and two is a bad quarter of an hour; a CI sensor on its
  default `*/15` cron reaches three in 45 minutes.
  """
  @spec threshold() :: pos_integer()
  def threshold, do: Application.get_env(:custode, :sensor_failure_threshold, @default_threshold)

  @doc """
  Record one failed run and return the streak as it now stands.

  Read, then write, with no lock: a sensor's runs are serialized by its own
  cron line, so nothing else increments this count.
  """
  @spec record_failure(String.t(), term()) :: t()
  def record_failure(sensor_id, reason) do
    now = DateTime.utc_now()

    health =
      case get(sensor_id) do
        nil -> %{failures: 1, last_error: describe(reason), since: now}
        previous -> %{previous | failures: previous.failures + 1, last_error: describe(reason)}
      end

    :ok = Memory.remember(@scope <> sensor_id, @key, encode(health))
    health
  end

  @doc "Record one successful run: the streak is over, so nothing is kept."
  @spec record_success(String.t()) :: :ok
  def record_success(sensor_id), do: Memory.forget(@scope <> sensor_id, @key)

  @doc "The sensor's current failure streak, or nil when its last run succeeded."
  @spec get(String.t()) :: t() | nil
  def get(sensor_id) do
    case Memory.recall(@scope <> sensor_id, @key) do
      {:ok, json} -> decode(json)
      :error -> nil
    end
  end

  @doc """
  Every sensor with a failure streak, keyed by sensor id.

  One query for the whole fleet, matching `Custode.Gates.open_by_agent/0` and
  `Custode.Asks.open_by_agent/0`, so resolving attention does not issue one
  read per sensor.
  """
  @spec failing() :: %{String.t() => t()}
  def failing do
    from(m in Memory.Entry,
      where: m.key == @key and like(m.agent_id, ^(@scope <> "%")),
      select: {m.agent_id, m.value}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {@scope <> sensor_id, json} ->
      case decode(json) do
        nil -> []
        health -> [{sensor_id, health}]
      end
    end)
    |> Map.new()
  end

  @doc """
  An error as one line a human can read.

  A string is already that. Anything else is inspected, which is what the
  feed line always showed.
  """
  @spec describe(term()) :: String.t()
  def describe(reason) when is_binary(reason) do
    reason |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, @error_cap)
  end

  def describe(reason) when is_exception(reason), do: reason |> Exception.message() |> describe()
  def describe(reason), do: reason |> inspect() |> describe()

  defp encode(health) do
    Jason.encode!(%{
      "failures" => health.failures,
      "last_error" => health.last_error,
      "since" => health.since && DateTime.to_iso8601(health.since)
    })
  end

  # A value that does not parse as this module's shape reads as no streak.
  # `failing/0` sits under every attention read in the fleet, so one bad row
  # must not be able to crash the fleet page, the inbox and the chip at once.
  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{"failures" => failures, "last_error" => error} = stored}
      when is_integer(failures) and failures > 0 and is_binary(error) ->
        %{failures: failures, last_error: error, since: parse(stored["since"])}

      _other ->
        nil
    end
  end

  defp parse(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parse(_absent), do: nil
end
