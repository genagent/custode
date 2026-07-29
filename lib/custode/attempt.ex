defmodule Custode.Attempt do
  @moduledoc "One durable, bounded deterministic or model-backed execution."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{ContextBundle, RoleBinding, WorkGate, WorkItem}

  @states ~w(queued running succeeded partial blocked failed cancelled)
  @terminal_states @states -- ~w(queued running)
  @executor_kinds ~w(deterministic model)

  schema "attempts" do
    field(:attempt_id, :string)
    belongs_to(:work_item, WorkItem)
    belongs_to(:role_binding, RoleBinding)
    belongs_to(:context_bundle, ContextBundle)
    belongs_to(:caused_by_attempt, __MODULE__)
    field(:executor_kind, :string)
    field(:provider, :string)
    field(:profile, :string)
    field(:recipe_version, :string)
    field(:state, :string, default: "queued")
    field(:context_digest, :string)
    field(:oban_job_id, :integer)
    field(:workflow_run_id, :string)
    field(:provider_continuation, :map)
    field(:expected_work_item_version, :integer)
    field(:provenance, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:usage, :map, default: %{})
    field(:outcome, :map)
    field(:error_class, :string)
    field(:error_details, :map)
    has_many(:gates, WorkGate)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :attempt_id,
      :work_item_id,
      :context_bundle_id,
      :executor_kind,
      :provider,
      :profile,
      :recipe_version,
      :state,
      :context_digest,
      :expected_work_item_version,
      :provenance,
      :usage
    ])
    |> validate_inclusion(:executor_kind, @executor_kinds)
    |> validate_inclusion(:state, ["queued"])
    |> validate_number(:expected_work_item_version, greater_than: 0)
    |> apply_constraints()
  end

  @doc false
  def start_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:state, :started_at, :oban_job_id, :workflow_run_id])
    |> validate_required([:state, :started_at])
    |> validate_inclusion(:state, ["running"])
    |> apply_constraints()
  end

  @doc false
  def finish_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :state,
      :finished_at,
      :usage,
      :outcome,
      :error_class,
      :error_details,
      :provider_continuation
    ])
    |> validate_required([:state, :finished_at, :usage, :outcome])
    |> validate_inclusion(:state, @terminal_states)
    |> validate_error()
    |> apply_constraints()
  end

  def states, do: @states
  def terminal_states, do: @terminal_states
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  defp fields do
    [
      :attempt_id,
      :work_item_id,
      :role_binding_id,
      :context_bundle_id,
      :caused_by_attempt_id,
      :executor_kind,
      :provider,
      :profile,
      :recipe_version,
      :state,
      :context_digest,
      :oban_job_id,
      :workflow_run_id,
      :provider_continuation,
      :expected_work_item_version,
      :provenance,
      :started_at,
      :finished_at,
      :usage,
      :outcome,
      :error_class,
      :error_details
    ]
  end

  defp validate_error(changeset) do
    if get_field(changeset, :state) in ~w(failed blocked) do
      validate_required(changeset, [:error_class])
    else
      changeset
    end
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:role_binding_id)
    |> foreign_key_constraint(:context_bundle_id)
    |> foreign_key_constraint(:caused_by_attempt_id)
    |> unique_constraint(:attempt_id)
    |> unique_constraint(:oban_job_id)
  end
end
