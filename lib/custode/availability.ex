defmodule Custode.Availability do
  @moduledoc """
  Provider subscription availability as a typed, optional policy input (#393).

  Autonomous scheduling knows Custode's own spend and token history but not
  how close the operator is to a provider's subscription ceiling. So the
  fleet can start low-priority work on an expensive model minutes before a
  five-hour limit is exhausted, and the first thing anyone learns about it is
  the rejection.

  ## Evidence, never authority

  Availability can make policy pick a cheaper model, a different eligible
  Executor, or a later start. It can NEVER widen a spend rail, grant a
  capability, skip a WorkspaceLease, or pass a Gate. Every existing safeguard
  runs exactly as it did whether or not a snapshot exists.

  ## Three states, and none of them is zero

      fresh     a recent observation, usable
      stale     an observation too old to describe now
      unknown   no observation, or a collector that failed

  Stale and unknown both mean "do not know", and neither is rendered or
  evaluated as 0% utilization. Defaulting a missing number to zero would
  license the most expensive model at exactly the moment the account is
  closest to its ceiling.

  ## Not knowing does not stop work

  Absence, staleness and collector failure all advise `:proceed`. The
  conservative reading of "we cannot see the quota" is to leave every other
  safeguard in charge, not to halt the fleet: a broken collector must not
  become an outage, and #393 asks explicitly that collector failure leave
  spend, authorization and scheduling intact.

  Conservatism shows up in the other direction. Availability is only ever
  allowed to make a choice SMALLER, so an absent snapshot can never justify
  more than the fleet would otherwise have done.

  ## Rejection is a constraint; pressure is a posture

  A provider that is rejecting is a scheduling fact, so work defers until the
  reported reset. High utilization BELOW rejection is a judgment call and
  therefore operator-configurable: `:ignore`, `:reduce`, or `:defer`. The
  default is `:reduce`, which spends less rather than stopping.
  """

  alias Custode.Availability.{Advice, Bucket, Snapshot}

  @table :custode_availability
  @policy_version "availability:v1"
  @max_age_seconds 900
  @warn_utilization 0.8

  @doc "Create the observation cache. Called once from application start."
  @spec attach() :: :ok
  def attach do
    ensure_table()
    :ok
  end

  @doc """
  Cache one provider observation.

  Last write wins per provider. An observation is a point-in-time reading, so
  an older one has nothing to contribute once a newer one exists.
  """
  @spec put(Snapshot.t()) :: :ok
  def put(%Snapshot{} = snapshot) do
    ensure_table()
    :ets.insert(@table, {snapshot.provider, snapshot})
    :ok
  end

  @doc "The cached observation for `provider`, or nil."
  @spec current(String.t()) :: Snapshot.t() | nil
  def current(provider) when is_binary(provider) do
    ensure_table()

    case :ets.lookup(@table, provider) do
      [{^provider, %Snapshot{} = snapshot}] -> snapshot
      _absent -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Forget one provider's observation, or all of them."
  @spec forget(String.t() | :all) :: :ok
  def forget(:all) do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def forget(provider) when is_binary(provider) do
    ensure_table()
    :ets.delete(@table, provider)
    :ok
  end

  @doc """
  What availability advises for `provider` right now.

  Options: `:now`, and any posture key to override configuration.
  """
  @spec advise(String.t(), keyword()) :: Advice.t()
  def advise(provider, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    posture = posture(options)

    case current(provider) do
      nil ->
        Advice.unknown("no availability observation for #{provider}", posture.version)

      snapshot ->
        weigh(snapshot, posture, now)
    end
  end

  @doc """
  The availability record to attach to an Attempt's provenance.

  Recorded even when the advice is `:proceed`, and even when nothing was
  observed at all. "We looked and there was headroom" and "we never looked"
  are different facts, and only one of them is reconstructible afterwards if
  the absent case writes nothing.
  """
  @spec provenance(String.t(), keyword()) :: map()
  def provenance(provider, options \\ []) when is_binary(provider),
    do: provider |> advise(options) |> Advice.render()

  @doc "The posture: configuration merged with per-call overrides."
  @spec posture(keyword()) :: map()
  def posture(options \\ []) do
    configured = Application.get_env(:custode, :availability_posture, [])

    %{
      version: fetch(options, configured, :version, @policy_version),
      max_age_seconds: fetch(options, configured, :max_age_seconds, @max_age_seconds),
      warn_utilization: fetch(options, configured, :warn_utilization, @warn_utilization),
      on_warning: fetch(options, configured, :on_warning, :reduce)
    }
  end

  defp fetch(options, configured, key, default) do
    Keyword.get(options, key, Keyword.get(List.wrap(configured), key, default))
  end

  defp weigh(snapshot, posture, now) do
    case Snapshot.freshness(snapshot, posture.max_age_seconds, now) do
      :stale ->
        Advice.stale(snapshot, posture.version, now)

      :fresh ->
        snapshot
        |> decision(posture)
        |> Advice.new(snapshot, posture.version, now)
    end
  end

  # Rejection is a scheduling fact and is not configurable. Pressure short of
  # rejection is a judgment, so the operator sets what it costs.
  defp decision(snapshot, posture) do
    cond do
      Snapshot.status(snapshot) == :rejected ->
        {:defer, Snapshot.rejected_until(snapshot), "the provider is rejecting requests"}

      pressured?(snapshot, posture) ->
        pressure(snapshot, posture)

      true ->
        {:proceed, nil, "reported availability is within its warning threshold"}
    end
  end

  defp pressured?(snapshot, posture) do
    Snapshot.status(snapshot) == :warning or
      Enum.any?(snapshot.buckets, &Bucket.over?(&1, posture.warn_utilization))
  end

  defp pressure(_snapshot, %{on_warning: :ignore}),
    do: {:proceed, nil, "utilization is high and the configured posture ignores it"}

  defp pressure(snapshot, %{on_warning: :defer}),
    do: {:defer, soonest_reset(snapshot), "utilization is high and the posture defers"}

  defp pressure(_snapshot, _posture),
    do: {:reduce, nil, "utilization is high; prefer a cheaper eligible option"}

  defp soonest_reset(snapshot) do
    snapshot.buckets
    |> Enum.map(& &1.resets_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _existing -> @table
    end
  rescue
    # a concurrent creator won the race, which is the outcome we wanted
    ArgumentError -> @table
  end
end
