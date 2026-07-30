defmodule Custode.Availability.Bucket do
  @moduledoc """
  One provider quota window, described in provider-neutral terms (#393).

  ## Identity is opaque, shape is not

  `id` is whatever the provider called it and carries no meaning here. Codex
  says `primary`; that string does not tell this module which window it is,
  and treating it as if it did would bake one provider's vocabulary into core
  policy. Selection uses `window_seconds` and `limit_type`, which are
  reported, comparable, and survive a provider renaming its buckets.

  ## Unknown is not zero

  `utilization` is `nil` when the provider did not report it. It is never
  defaulted to `0.0`. A missing number that reads as "no usage" is the exact
  failure #393 exists to prevent: it would license the most expensive model
  at the moment the account is closest to its ceiling.
  """

  @enforce_keys [:id, :status]
  defstruct [:id, :status, :window_seconds, :limit_type, :utilization, :resets_at, extra: %{}]

  @type status :: :ok | :warning | :rejected | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          window_seconds: pos_integer() | nil,
          limit_type: String.t() | nil,
          utilization: float() | nil,
          resets_at: DateTime.t() | nil,
          extra: map()
        }

  @doc "Is this bucket at or over `threshold` utilization? Unknown is never over."
  @spec over?(t(), float()) :: boolean()
  def over?(%__MODULE__{utilization: nil}, _threshold), do: false
  def over?(%__MODULE__{utilization: used}, threshold), do: used >= threshold

  @doc "The wire shape recorded on Attempt provenance."
  @spec render(t()) :: map()
  def render(%__MODULE__{} = bucket) do
    %{
      "id" => bucket.id,
      "status" => Atom.to_string(bucket.status),
      "window_seconds" => bucket.window_seconds,
      "limit_type" => bucket.limit_type,
      "utilization" => bucket.utilization,
      "resets_at" => bucket.resets_at && DateTime.to_iso8601(bucket.resets_at),
      "extra" => bucket.extra
    }
  end
end
