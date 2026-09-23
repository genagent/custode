defmodule Custode.Disowned do
  @moduledoc """
  Pull requests an agent has declared are not its work (#313).

  ## What this is for

  design/000 says a red check reaches the operator when it is one "the crew
  has declared not theirs". design/007 could not honour that and defaulted to
  the safe half: every red check went to `:watching`, on the reasoning that an
  agent which beats daily will look at its own.

  That reasoning is right and it misses a case. `mdbook-lint` sat in
  `:watching` on `#400`, a genuinely failing check, while its own panel read:

      Not mine, do not touch
      #400 -- human's LSP config fix

  Its next beat would not fix it, nor the one after. Nobody would, except the
  operator. The declaration existed; it was prose in an `agent_panels` blob,
  so nothing could act on it.

  This makes it a fact. A red check on a disowned PR resolves to
  `:disowned_check` in `:needs_you`; everything else stays `:red_check` in
  `:watching`.

  ## Disowning is a judgment, so it has an author

  Every row records which agent decided, and why. A disownment that turns out
  to be wrong should be traceable to the reasoning that produced it, and
  `reclaim/2` exists so being wrong is reversible.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @type t :: %__MODULE__{}

    schema "disowned_prs" do
      field(:repo, :string)
      field(:number, :integer)
      field(:agent_id, :string)
      field(:reason, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc """
  Record that `number` in `repo` is not `agent_id`'s work.

  Idempotent on repo + number: a second agent reaching the same conclusion is
  not new information, so the original judgment and its author stand.
  """
  @spec disown(String.t(), String.t(), integer(), String.t() | nil) ::
          {:ok, Row.t()} | {:error, term()}
  def disown(agent_id, repo, number, reason \\ nil) do
    case get(repo, number) do
      %Row{} = existing ->
        {:ok, existing}

      nil ->
        {:ok,
         Repo.insert!(%Row{
           repo: repo,
           number: number,
           agent_id: agent_id,
           reason: reason
         })}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Undo a disownment: the PR is somebody's work again."
  @spec reclaim(String.t(), integer()) :: :ok | {:error, :not_disowned}
  def reclaim(repo, number) do
    case get(repo, number) do
      nil -> {:error, :not_disowned}
      %Row{} = row -> reclaim(row)
    end
  end

  @doc "Undo the exact disownment row that was authorized by its caller."
  @spec reclaim(Row.t()) :: :ok | {:error, :not_disowned}
  def reclaim(%Row{} = row) do
    Repo.delete!(row)
    :ok
  rescue
    Ecto.StaleEntryError -> {:error, :not_disowned}
  end

  @doc "The disownment for this PR, or nil."
  @spec get(String.t(), integer()) :: Row.t() | nil
  def get(repo, number) do
    Repo.one(from(d in Row, where: d.repo == ^repo and d.number == ^number))
  end

  @doc "Every disownment, newest first."
  @spec all() :: [Row.t()]
  def all, do: Repo.all(from(d in Row, order_by: [desc: d.id]))

  @doc """
  The disowned PR numbers for `repo`, as a set.

  One query per repo, and the resolver calls it while building views, so the
  shape is the one a membership test wants rather than a list to scan.
  """
  @spec numbers(String.t()) :: MapSet.t(integer())
  def numbers(repo) do
    from(d in Row, where: d.repo == ^repo, select: d.number)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Disowned numbers for every repo at once, as `%{repo => MapSet}`."
  @spec by_repo() :: %{String.t() => MapSet.t(integer())}
  def by_repo do
    from(d in Row, select: {d.repo, d.number})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {repo, numbers} -> {repo, MapSet.new(numbers)} end)
  end
end
