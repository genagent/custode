defmodule Custode.NextBeat do
  @moduledoc """
  An agent's one-shot request for when it should next run (#526).

  A routine runs on its cron whatever it found last time. An agent that knows
  CI takes forty minutes, or that nothing can move until a release lands
  tomorrow, could not say so, and spent its next beats finding that out
  again. `request/3` lets it say so, within bounds the operator owns.

  The request is ONE-SHOT and it only ever concerns the scheduler:

    * until `at`, the routine's cron beats are skipped
      (`Custode.Scheduler.due/4`);
    * at `at` it fires once, whether or not the cron matches, and the request
      is gone;
    * anything that starts a turn in the meantime (an operator message, a
      sensor wake, an inbox note, `beat now`, an approval) clears it. Those
      never went through the scheduler, and each of them means the world the
      agent was waiting on has changed.

  The wait is clamped to `config :custode, :next_beat_bounds` (minutes,
  default 5 to 1440). Policy narrows and never grants: an agent cannot use
  this to run MORE often than the floor, and the clamp is reported back so it
  knows what it got.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @primary_key {:routine_id, :string, autogenerate: false}
  schema "next_beats" do
    field(:at, :utc_datetime_usec)
    field(:reason, :string)
    field(:requested_minutes, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @default_bounds {5, 1440}

  @doc "The `{min, max}` wait in minutes."
  @spec bounds() :: {pos_integer(), pos_integer()}
  def bounds, do: Application.get_env(:custode, :next_beat_bounds, @default_bounds)

  @doc """
  Record `routine_id`'s request to run next in `minutes`, clamped to the
  bounds. Replaces any earlier request. Returns the time granted and the
  minutes it came to, which differ from what was asked when the clamp bit.
  """
  @spec request(String.t(), integer(), keyword()) ::
          {:ok, %{at: DateTime.t(), minutes: pos_integer(), clamped?: boolean()}}
  def request(routine_id, minutes, opts \\ [])
      when is_binary(routine_id) and is_integer(minutes) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    {low, high} = bounds()
    granted = minutes |> max(low) |> min(high)
    # the column is microsecond precision; a caller's clock may not be
    at = now |> DateTime.add(granted * 60, :second) |> with_usec()

    Repo.insert!(
      %__MODULE__{
        routine_id: routine_id,
        at: at,
        reason: Keyword.get(opts, :reason),
        requested_minutes: minutes
      },
      on_conflict: {:replace, [:at, :reason, :requested_minutes, :inserted_at]},
      conflict_target: :routine_id
    )

    {:ok, %{at: at, minutes: granted, clamped?: granted != minutes}}
  end

  defp with_usec(%DateTime{microsecond: {value, _precision}} = at),
    do: %{at | microsecond: {value, 6}}

  @doc "Every pending request, as `%{routine_id => at}`. What the scheduler reads each minute."
  @spec pending() :: %{String.t() => DateTime.t()}
  def pending, do: Repo.all(from(n in __MODULE__, select: {n.routine_id, n.at})) |> Map.new()

  @doc "Every pending request keyed by routine id, including its durable identity."
  @spec pending_requests() :: %{String.t() => %__MODULE__{}}
  def pending_requests do
    __MODULE__
    |> Repo.all()
    |> Map.new(&{&1.routine_id, &1})
  end

  @doc "One routine's pending request, or `nil`."
  @spec get(String.t()) :: %__MODULE__{} | nil
  def get(routine_id), do: Repo.get(__MODULE__, routine_id)

  @doc "Forget a routine's request (idempotent)."
  @spec clear(String.t()) :: :ok
  def clear(routine_id) do
    Repo.delete_all(from(n in __MODULE__, where: n.routine_id == ^routine_id))
    :ok
  end

  @doc "Delete only the exact request observed by the scheduler."
  @spec clear_observed(%__MODULE__{}) :: non_neg_integer()
  def clear_observed(%__MODULE__{} = request) do
    {count, _rows} =
      Repo.delete_all(
        from(n in __MODULE__,
          where:
            n.routine_id == ^request.routine_id and n.at == ^request.at and
              n.inserted_at == ^request.inserted_at
        )
      )

    count
  end

  @doc "Clear a request the moment its agent starts a turn, whoever started it."
  def attach do
    :telemetry.attach_many(
      "custode-next-beat",
      [
        [:oban_claude, :agent, :transition],
        [:oban_codex, :agent, :transition]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  # :telemetry detaches a handler that raises; never raise out of one.
  @doc false
  def handle_event(_event, _measurements, %{to: :running, agent_id: agent_id}, _config) do
    clear(agent_id)
  rescue
    _exception -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
