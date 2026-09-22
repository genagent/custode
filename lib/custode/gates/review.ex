defmodule Custode.Gates.Review do
  @moduledoc """
  One sealed cross-provider review of one pull-request head.

  Reviews are reusable evidence. The unique repository, pull request and head
  tuple means a second gate at an unchanged head attaches the existing review
  instead of spending another model turn.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "gate_reviews" do
    field(:repo, :string)
    field(:pr_number, :integer)
    field(:head_sha, :string)
    field(:author_provider, :string)
    field(:reviewer_provider, :string)
    field(:round, :integer)
    field(:status, :string, default: "pending")
    field(:evidence_digest, :string)
    field(:summary, :string)
    field(:findings, :string)
    field(:error, :string)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(repo pr_number head_sha author_provider reviewer_provider round status)a

  def changeset(review, attrs) do
    review
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:repo, :pr_number, :head_sha])
  end

  @doc "The decoded findings, or an empty list while none are available."
  def findings(%__MODULE__{findings: findings}) when is_binary(findings) do
    case Jason.decode(findings) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _other -> []
    end
  end

  def findings(_review), do: []
end
