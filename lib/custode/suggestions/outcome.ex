defmodule Custode.Suggestions.Outcome do
  @moduledoc """
  What happened after the operator decided (#303).

  ## Why this exists

  A suggestion currently has two states: standing, and gone. Applying one
  makes the card vanish, so the system never learns whether the advice was any
  good, and neither does the advisor. That is the difference between a
  suggestion generator and something that improves: it proposes forever and is
  never told.

  This is the record. Every decision the operator made in the window, with
  what has happened since.

  ## Facts, not verdicts

  design/005's arc asks for a verdict -- confirmed, no effect, reverted,
  superseded. Three of those four are decidable from state the fleet already
  keeps, and the interesting one is not:

    * `:reverted` -- the roster no longer holds the applied value. Whoever
      changed it, the suggestion did not survive contact.
    * `:superseded` -- the agent is gone from the roster. Not a failure, just
      not a lesson.
    * `:observing` -- the window has not elapsed. There is nothing to say yet,
      and saying it anyway is how a record becomes noise.
    * `:settled` -- applied, still in force, window elapsed.

  `:settled` deliberately does NOT claim "confirmed". Whether a change did
  what it promised depends on what it promised, and that is per-advisor: a
  budget raise claims interruptions will stop, a model change claims yield
  will hold at lower cost. Inventing one verdict rule for all of them would
  produce a confident label with nothing behind it, which is worse than a
  fact.

  So a settled record carries OBSERVED FACTS instead, and they are the same
  facts for every field:

      applied 6d ago, zero rail-stops since, peak $312.40

  That sentence is what turns a feed of proposals into a record of judgment,
  and it is true whatever the advisor claimed. A per-advisor verdict can be
  layered on top of these numbers later; it cannot be layered on top of
  nothing.

  ## Dismissals are here too

  A dismissal with a reason (#303) is the cheapest signal in the system and
  the only one that arrives without waiting out a window, so it belongs in
  the same record rather than a separate one.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Feed
  alias Custode.Repo
  alias Custode.Routine
  alias Custode.SpendLedger
  alias Custode.Suggestions

  # How long an applied change is watched before its record settles. Long
  # enough for a daily-cadence fleet to have exercised the change several
  # times, short enough that the operator sees an answer in the same week.
  @observation_days 3
  @window_s 30 * 24 * 60 * 60

  defmodule Record do
    @moduledoc "One operator decision and what has happened since."

    @type status :: :observing | :settled | :reverted | :superseded | :dismissed

    @type t :: %__MODULE__{
            agent: String.t(),
            advisor: String.t() | nil,
            field: String.t(),
            proposed: String.t(),
            decision: :applied | :dismissed,
            status: status(),
            reason: String.t() | nil,
            at: DateTime.t() | nil,
            observed: map() | nil
          }

    defstruct [:agent, :advisor, :field, :proposed, :decision, :status, :reason, :at, :observed]
  end

  @doc """
  Every decision in the window, newest first.

  Options: `:since` (seconds, default 30 days), `:now` (the clock, for tests).
  """
  @spec history(keyword()) :: [Record.t()]
  def history(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = Keyword.get(opts, :since, @window_s)

    applied = Feed.recent_by_event("advisor_applied", limit: 100, since: since, now: now)
    dismissed = Feed.recent_by_event("advisor_dismissed", limit: 100, since: since, now: now)

    records =
      Enum.map(applied, &applied_record(&1, now)) ++
        Enum.map(dismissed, &dismissed_record/1)

    Enum.sort_by(records, & &1.at, {:desc, DateTime})
  end

  @doc "How many days an applied change is watched before its record settles."
  @spec observation_days() :: pos_integer()
  def observation_days, do: @observation_days

  defp applied_record(entry, now) do
    agent = entry["agent"]
    field = entry["field"]
    proposed = entry["proposed"]
    at = parse(entry["at"])

    %Record{
      agent: agent,
      advisor: entry["advisor"],
      field: field,
      proposed: proposed,
      decision: :applied,
      status: status(agent, field, proposed, at, now),
      at: at,
      observed: at && observed(agent, at, now)
    }
  end

  defp dismissed_record(entry) do
    %Record{
      agent: entry["agent"],
      advisor: entry["advisor"],
      field: entry["field"],
      proposed: entry["proposed"],
      decision: :dismissed,
      status: :dismissed,
      reason: entry["reason"],
      at: parse(entry["at"])
    }
  end

  # Order matters. A gone agent is superseded even if its last known value
  # differed, because "reverted" would imply a decision somebody made about
  # the change rather than about the agent.
  defp status(agent, field, proposed, at, now) do
    case Routine.get(agent) do
      nil ->
        :superseded

      routine ->
        cond do
          not holds?(routine, field, proposed) -> :reverted
          observing?(at, now) -> :observing
          true -> :settled
        end
    end
  end

  # The roster is the truth about whether a change is still in force. Compared
  # as strings because that is how a suggestion carries its value, and a float
  # round-trips differently than it was proposed.
  defp holds?(routine, field, proposed) do
    current = Map.get(routine, field_key(field))
    current != nil and to_string(current) == to_string(proposed)
  end

  defp field_key("model"), do: :model
  defp field_key("cron"), do: :cron
  defp field_key("daily_budget_usd"), do: :daily_budget_usd
  defp field_key(other), do: String.to_atom(other)

  defp observing?(nil, _now), do: false

  defp observing?(at, now) do
    DateTime.diff(now, at, :second) < @observation_days * 24 * 60 * 60
  end

  # The same facts for every field, because they are true whatever the
  # advisor claimed. A rail-stop is the fleet interrupting its own work, and
  # peak spend is what the rail would have to allow.
  defp observed(agent, at, now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    %{
      days: div(seconds, 24 * 60 * 60),
      rail_stops:
        length(
          Feed.recent_by_event("budget_paused",
            agent: agent,
            since: seconds,
            now: now
          )
        ),
      peak_usd: peak_daily_spend(agent, at)
    }
  end

  # Highest single DAY of spend since the change, which is the number a rail
  # is set against. A window total would hide the shape.
  defp peak_daily_spend(agent, since) do
    from(s in SpendLedger.Entry,
      where: s.agent_id == ^agent and s.inserted_at >= ^since,
      group_by: fragment("date(?)", s.inserted_at),
      select: sum(s.cost_usd)
    )
    |> Repo.all()
    |> Enum.map(&to_float/1)
    |> Enum.max(fn -> 0.0 end)
  end

  defp to_float(nil), do: 0.0
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp parse(%DateTime{} = at), do: at

  defp parse(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  defp parse(_other), do: nil

  @doc """
  A one-line rendering of a record, for a card or a CLI row.

      applied 6d ago, 0 rail-stops since, peak $312.40
  """
  @spec describe(Record.t()) :: String.t()
  def describe(%Record{decision: :dismissed} = record) do
    case Suggestions.dismiss_reason_label(record.reason) do
      nil -> "dismissed"
      label -> "dismissed: #{label}"
    end
  end

  def describe(%Record{status: :superseded}), do: "superseded: the agent is gone"

  def describe(%Record{status: :reverted} = record),
    do: "reverted: #{record.field} no longer holds #{record.proposed}"

  def describe(%Record{observed: nil}), do: "applied"

  def describe(%Record{status: status, observed: observed}) do
    tail = if status == :observing, do: " (still watching)", else: ""

    "applied #{observed.days}d ago, #{observed.rail_stops} rail-stop(s) since, " <>
      "peak $#{:erlang.float_to_binary(observed.peak_usd, decimals: 2)}#{tail}"
  end
end
