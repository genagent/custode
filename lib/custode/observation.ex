defmodule Custode.Observation do
  @moduledoc """
  One aggregated, evidence-backed observation of a condition (#246).

  A row is a CONDITION, not a sighting. Seeing the same thing again
  increments `occurrences` and moves `last_observed_at`; it never inserts a
  second row. That is what makes "this has happened three times" a threshold
  rather than a count of rows nobody deduplicated.

  ## Dispositions

      watching     evidence is accumulating and no threshold has been met
      proposed     a control WorkItem was created under an auto posture
      gated        an operator decision was requested before creating one
      ineligible   policy declined, visibly and with a reason
      rejected     the observation was refused, currently only for recursion

  `ineligible` and `rejected` are recorded rather than dropped. An
  observation that silently disappears is indistinguishable from one that was
  never made, and #246 exists partly so systemic drift stops being invisible.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.Mission

  @dispositions ~w(watching proposed gated ineligible rejected)

  schema "observations" do
    field(:observation_id, :string)
    field(:dedup_key, :string)
    field(:source, :string)
    field(:target, :string)
    field(:revision, :string)
    field(:evidence, :map, default: %{})
    field(:occurrences, :integer, default: 1)
    field(:first_observed_at, :utc_datetime_usec)
    field(:last_observed_at, :utc_datetime_usec)
    belongs_to(:mission, Mission)
    field(:disposition, :string, default: "watching")
    field(:disposition_reason, :map, default: %{})
    field(:threshold_version, :string)
    field(:policy_version, :string)
    field(:control_work_item_id, :string)
    field(:gate_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Dispositions an observation may carry."
  def dispositions, do: @dispositions

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :observation_id,
      :dedup_key,
      :source,
      :target,
      :revision,
      :evidence,
      :occurrences,
      :first_observed_at,
      :last_observed_at,
      :mission_id,
      :disposition,
      :disposition_reason
    ])
    |> validate_required([
      :observation_id,
      :dedup_key,
      :source,
      :target,
      :first_observed_at,
      :last_observed_at
    ])
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_number(:occurrences, greater_than: 0)
    |> unique_constraint(:dedup_key)
    |> unique_constraint(:observation_id)
    |> foreign_key_constraint(:mission_id)
  end

  @doc false
  def disposition_changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :disposition,
      :disposition_reason,
      :threshold_version,
      :policy_version,
      :control_work_item_id,
      :gate_id,
      :mission_id
    ])
    |> validate_required([:disposition])
    |> validate_inclusion(:disposition, @dispositions)
  end
end
