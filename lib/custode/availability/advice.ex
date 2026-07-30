defmodule Custode.Availability.Advice do
  @moduledoc """
  What availability advises, and why (#393).

  Three decisions, and each can only make a launch smaller or later:

      proceed   nothing about availability changes the choice
      reduce    prefer a cheaper eligible Executor, model or effort
      defer     do not launch until `defer_until`

  There is deliberately no `expand`. Availability is evidence, and evidence
  that could talk the fleet into spending more than policy already allowed
  would be a spend rail with extra steps.

  `reason` is prose because a deferral someone cannot explain is a deferral
  they will switch off. The rendered shape is what an Attempt records, so the
  observation identity, its age, its buckets and the policy version travel
  with the work rather than being reconstructed from logs later.
  """

  alias Custode.Availability.Snapshot

  @enforce_keys [:decision, :freshness, :reason, :policy_version]
  defstruct [:decision, :freshness, :reason, :policy_version, :defer_until, :observation]

  @type decision :: :proceed | :reduce | :defer

  @type t :: %__MODULE__{
          decision: decision(),
          freshness: :fresh | :stale | :unknown,
          reason: String.t(),
          policy_version: String.t(),
          defer_until: DateTime.t() | nil,
          observation: map() | nil
        }

  @doc "No observation at all, or a collector that failed."
  @spec unknown(String.t(), String.t()) :: t()
  def unknown(reason, policy_version) do
    %__MODULE__{
      decision: :proceed,
      freshness: :unknown,
      reason: reason,
      policy_version: policy_version
    }
  end

  @doc """
  An observation too old to describe now.

  Reported as unusable rather than discarded: the identity and age still
  travel onto the Attempt, so "we looked and it was stale" is distinguishable
  from "we never looked".
  """
  @spec stale(Snapshot.t(), String.t(), DateTime.t()) :: t()
  def stale(%Snapshot{} = snapshot, policy_version, now) do
    %__MODULE__{
      decision: :proceed,
      freshness: :stale,
      reason:
        "the newest #{snapshot.provider} observation is " <>
          "#{Snapshot.age_seconds(snapshot, now)}s old and no longer describes now",
      policy_version: policy_version,
      observation: Snapshot.render(snapshot, now)
    }
  end

  @doc false
  @spec new({decision(), DateTime.t() | nil, String.t()}, Snapshot.t(), String.t(), DateTime.t()) ::
          t()
  def new({decision, defer_until, reason}, %Snapshot{} = snapshot, policy_version, now) do
    %__MODULE__{
      decision: decision,
      freshness: :fresh,
      reason: reason,
      policy_version: policy_version,
      defer_until: defer_until,
      observation: Snapshot.render(snapshot, now)
    }
  end

  @doc "Does this advice permit launching now?"
  @spec launchable?(t()) :: boolean()
  def launchable?(%__MODULE__{decision: :defer}), do: false
  def launchable?(%__MODULE__{}), do: true

  @doc "The wire shape recorded on Attempt provenance."
  @spec render(t()) :: map()
  def render(%__MODULE__{} = advice) do
    %{
      "decision" => Atom.to_string(advice.decision),
      "freshness" => Atom.to_string(advice.freshness),
      "reason" => advice.reason,
      "policy_version" => advice.policy_version,
      "defer_until" => advice.defer_until && DateTime.to_iso8601(advice.defer_until),
      "observation" => advice.observation
    }
  end
end
