defmodule Custode.Availability.Snapshot do
  @moduledoc """
  One provider's reported subscription availability at a moment (#393).

  Availability is EVIDENCE, not authority. A snapshot can make policy choose a
  cheaper model or wait for a reset. It can never widen a spend rail, grant a
  capability, skip a WorkspaceLease, or pass a Gate.

  ## Freshness is separate from status

  `status` is what the provider said. Freshness is how long ago it said it,
  derived from `observed_at`. Collapsing them loses the case that matters
  most: a snapshot reporting plenty of headroom an hour ago is not evidence
  of headroom now.

  Absence is a third thing again, and none of the three is "0% used".

  ## Unknown provider fields survive as evidence

  Anything the provider reported that this shape has no field for is kept in
  `extra`. Core policy never learns provider-specific names, and a provider
  adding a field does not require a release before that field is visible to
  whoever is debugging a deferral.
  """

  alias Custode.Availability.Bucket

  @enforce_keys [:provider, :source, :observed_at, :buckets]
  defstruct [:provider, :source, :observed_at, :account_scope, buckets: [], extra: %{}]

  @type t :: %__MODULE__{
          provider: String.t(),
          source: String.t(),
          observed_at: DateTime.t(),
          account_scope: String.t() | nil,
          buckets: [Bucket.t()],
          extra: map()
        }

  @doc "Seconds since the snapshot was observed."
  @spec age_seconds(t(), DateTime.t()) :: non_neg_integer()
  def age_seconds(%__MODULE__{} = snapshot, now),
    do: max(DateTime.diff(now, snapshot.observed_at, :second), 0)

  @doc "`:fresh` while within `max_age`, `:stale` after."
  @spec freshness(t(), pos_integer(), DateTime.t()) :: :fresh | :stale
  def freshness(%__MODULE__{} = snapshot, max_age, now),
    do: if(age_seconds(snapshot, now) <= max_age, do: :fresh, else: :stale)

  @doc "The worst status any bucket reports."
  @spec status(t()) :: Bucket.status()
  def status(%__MODULE__{buckets: []}), do: :unknown

  def status(%__MODULE__{buckets: buckets}) do
    cond do
      Enum.any?(buckets, &(&1.status == :rejected)) -> :rejected
      Enum.any?(buckets, &(&1.status == :warning)) -> :warning
      Enum.all?(buckets, &(&1.status == :unknown)) -> :unknown
      true -> :ok
    end
  end

  @doc """
  Buckets matching a selector, chosen by reported shape rather than name.

  Supports `:limit_type` and `:max_window_seconds`, so a caller can ask for
  "the short window" without knowing that one provider calls it `primary`.
  """
  @spec select(t(), keyword()) :: [Bucket.t()]
  def select(%__MODULE__{buckets: buckets}, selector \\ []) do
    Enum.filter(buckets, fn bucket ->
      matches_type?(bucket, selector[:limit_type]) and
        within_window?(bucket, selector[:max_window_seconds])
    end)
  end

  defp matches_type?(_bucket, nil), do: true
  defp matches_type?(bucket, type), do: bucket.limit_type == type

  defp within_window?(_bucket, nil), do: true
  defp within_window?(%Bucket{window_seconds: nil}, _max), do: false
  defp within_window?(%Bucket{window_seconds: window}, max), do: window <= max

  @doc "The soonest reset among buckets that are rejecting, or nil."
  @spec rejected_until(t()) :: DateTime.t() | nil
  def rejected_until(%__MODULE__{buckets: buckets}) do
    buckets
    |> Enum.filter(&(&1.status == :rejected))
    |> Enum.map(& &1.resets_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc "The wire shape recorded on Attempt provenance."
  @spec render(t(), DateTime.t()) :: map()
  def render(%__MODULE__{} = snapshot, now) do
    %{
      "provider" => snapshot.provider,
      "source" => snapshot.source,
      "account_scope" => snapshot.account_scope,
      "observed_at" => DateTime.to_iso8601(snapshot.observed_at),
      "age_seconds" => age_seconds(snapshot, now),
      "status" => Atom.to_string(status(snapshot)),
      "buckets" => Enum.map(snapshot.buckets, &Bucket.render/1),
      "extra" => snapshot.extra
    }
  end
end
