defmodule Custode.Presence do
  @moduledoc """
  Operator presence (#141 slice 1): is a human around right now?

  The signal is INFERRED from evidence the db already holds -- the newest
  operator action is the newest of:

    * a gate resolution (approve/reject/answer all touch `gates.updated_at`)
    * an operator-origin turn (the feed entries #138 marks with a response,
      i.e. a prompt the operator sent and got answered)

  with an EXPLICIT override on top: `Application.put_env(:custode,
  :presence_override, :present | :away)` pins the answer (the away/back tool
  and dashboard toggle set this; `nil` restores inference). Present means an
  action within `:presence_window_minutes` (default 45).

  Why it matters mechanically: a gate PARKS the proposing agent, so an agent
  that proposes into an empty room wastes its whole night parked. The
  rendered context line lets sweeps choose night-shaped work instead (#141
  slice 2 teaches the roles to read it).

  Rendered into every tick prompt at fire time -- #121/#142 make that live,
  so presence flips reach the very next sweep with no restart.

  ## A present pin lapses; an away pin does not (#328)

  `set(:present)` used to pin present unconditionally, and `status/1` applied
  no recency test to it at all. Pin it, walk away, and every sweep all night
  was told a human was around -- so agents proposed as soon as they had an
  item, and each proposal parked its agent until morning. That is the exact
  failure the presence line exists to prevent, reachable through the control
  meant to prevent it.

  So a present pin now carries the moment it was set and lapses into
  inference after the same window an inferred present gets. An AWAY pin does
  NOT lapse: pinning away is a statement of intent ("I am out"), and having
  it silently flip to present because the clock rolled over would be worse
  than useless.

  ## Absence is evidenced, not assumed (#328)

  "Has the operator acted recently?" also reads away when there was simply
  nothing to do, so a quiet fleet made a present operator look absent. The
  sharper question is "has the operator failed to answer something that was
  waiting?", and the db already records exactly that: an OPEN gate, an open
  work-scoped gate, or an open ask (#306), each with an aging `inserted_at`.

  An unanswered request older than `:presence_unanswered_minutes` (default
  90, deliberately longer than the action window) is near-proof nobody is
  home. Nothing waiting and no recent clicks is merely ambiguous, and reads
  present rather than guessing.

  The two rules compose into a system that corrects itself. A present
  reading with nothing waiting costs one proposal; that proposal becomes the
  open request whose aging then flips the reading to away, so the fleet
  learns the room is empty from the first gate rather than from the clock.
  Since #306 an ask is non-blocking, so an aging ask is pure evidence and
  costs nothing at all.
  """

  import Ecto.Query, only: [from: 2]

  @doc "The presence reading: `{:present, last_action_at}` | `{:away, last_action_at | nil}`."
  def status(now \\ DateTime.utc_now()) do
    {state, at, _why} = explain(now)
    {state, at}
  end

  @doc """
  The presence reading plus WHY it reads that way (#328):
  `{state, last_action_at, why}`.

  `why` is one of `{:pinned, :present | :away}`, `:recent_action`,
  `{:unanswered, oldest_request_at}`, or `:nothing_waiting`. `status/1` is
  this without the reason, and the rendered line uses it to say what the
  reading rests on.
  """
  def explain(now \\ DateTime.utc_now()) do
    last = last_operator_action_at()

    case override(now) do
      {:pinned, state} ->
        {state, last, {:pinned, state}}

      :infer ->
        infer(last, oldest_unanswered_request(), window_seconds(), unanswered_seconds(), now)
    end
  end

  @doc """
  Pure presence inference (#328), exposed for testing.

  Recent action wins outright: someone who just clicked is here, whatever is
  sitting unanswered. Otherwise an unanswered request older than
  `unanswered_window` is positive evidence of absence. Nothing waiting and
  nothing recent is ambiguous and reads present rather than guessing away.
  """
  def infer(last_action, oldest_request, window, unanswered_window, now) do
    cond do
      within?(last_action, window, now) ->
        {:present, last_action, :recent_action}

      aged?(oldest_request, unanswered_window, now) ->
        {:away, last_action, {:unanswered, oldest_request}}

      true ->
        {:present, last_action, :nothing_waiting}
    end
  end

  # An away pin is intent and never lapses. A present pin carries when it was
  # set and lapses into inference, so walking away from a pinned session stops
  # telling every sweep all night that a human is around (#328).
  defp override(now) do
    case Application.get_env(:custode, :presence_override) do
      :away ->
        {:pinned, :away}

      {:present, pinned_at} ->
        if within?(pinned_at, window_seconds(), now), do: {:pinned, :present}, else: :infer

      # A bare :present has no clock to lapse against. Only configuration sets
      # this shape now; `set/1` always stamps the pin.
      :present ->
        {:pinned, :present}

      _none ->
        :infer
    end
  end

  defp within?(nil, _window, _now), do: false
  defp within?(at, window, now), do: DateTime.diff(now, at, :second) <= window

  defp aged?(nil, _window, _now), do: false
  defp aged?(at, window, now), do: DateTime.diff(now, at, :second) > window

  @doc """
  The prompt context line for a tick (one line; roles read it, slice 2).
  """
  def render(now \\ DateTime.utc_now()) do
    {state, at, why} = explain(now)

    "\n## Operator presence\noperator: #{upcase(state)} (#{basis(why, at, now)})\n"
  end

  defp upcase(:present), do: "PRESENT"
  defp upcase(:away), do: "AWAY"

  # The reading is only useful to a sweep if the sweep can tell what it rests
  # on. An assumed present and an evidenced present should not read alike.
  defp basis({:pinned, state}, nil, _now), do: "pinned #{state}; no recorded actions yet"

  defp basis({:pinned, state}, at, now), do: "pinned #{state}; last action #{ago(at, now)}"
  defp basis(:recent_action, at, now), do: "last action #{ago(at, now)}"

  defp basis({:unanswered, since}, _at, now),
    do: "a request has been waiting #{ago(since, now)} unanswered"

  defp basis(:nothing_waiting, nil, _now), do: "assumed; nothing waiting, no recorded actions yet"

  defp basis(:nothing_waiting, at, now),
    do: "assumed; nothing waiting, last action #{ago(at, now)}"

  @doc """
  The explicit toggle (#141): `:away` pins away, `:present` pins present,
  `:auto` restores inference. Every toggle is recorded as a feed event that
  itself counts as an operator action -- so `back` (set `:auto`) reads
  present immediately and then expires naturally with the window, instead
  of needing a pin that never lapses.

  Since #328 a `:present` pin expires the same way: it is stamped with the
  moment it was set and lapses into inference after the presence window. An
  `:away` pin still does not expire, because it states an intention rather
  than reporting a recent keystroke.
  """
  def set(mode) when mode in [:present, :away, :auto] do
    Application.put_env(:custode, :presence_override, pin(mode))

    Custode.Feed.record(%{
      event: "presence",
      agent: "operator",
      summary: "operator marked #{mode}"
    })

    status()
  end

  # A present pin is stamped so it can lapse (#328); away is intent and is not.
  defp pin(:auto), do: nil
  defp pin(:away), do: :away
  defp pin(:present), do: {:present, DateTime.utc_now()}

  @doc """
  The away window on operator return (#263): `{:since, dt}` when the operator
  is present now but just came back from an absence of at least the presence
  window, else `:none`. The "while you were away" digest reads this.

  Gap-inferred (the operator's call): it walks the recent operator-action
  timeline (gate resolves, operator turns, presence toggles) newest-first and
  finds the first gap >= the presence window -- the older side of that gap is
  when the operator left. No explicit "away" toggle required, and it never
  fires when the operator has been continuously present.
  """
  def away_window(now \\ DateTime.utc_now()) do
    case status(now) do
      {:present, _at} -> away_from(recent_operator_actions(now), window_seconds(), now)
      _away -> :none
    end
  end

  @doc """
  Pure gap-finder (#263), exposed for testing: given operator-action
  timestamps newest-first, the presence `window` in seconds, and `now`, return
  `{:since, dt}` for the most recent absence >= the window whose RETURN is
  itself recent (within the window), else `:none`.
  """
  def away_from([newer, older | rest], window, now) do
    cond do
      DateTime.diff(newer, older) < window -> away_from([older | rest], window, now)
      DateTime.diff(now, newer) <= window -> {:since, older}
      true -> :none
    end
  end

  def away_from(_too_few, _window, _now), do: :none

  @doc "Operator-action timestamps over the last 48h, newest first (#263)."
  def recent_operator_actions(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -48 * 3600, :second)

    (gate_touches(since) ++ operator_turns(since) ++ presence_toggles(since))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort({:desc, DateTime})
  end

  defp window_seconds, do: Application.get_env(:custode, :presence_window_minutes, 45) * 60

  # Deliberately longer than the action window. An operator can leave a gate
  # open for half an hour while thinking about it; two windows of silence on
  # something that was waiting is a different claim.
  defp unanswered_seconds,
    do: Application.get_env(:custode, :presence_unanswered_minutes, 90) * 60

  @doc """
  The oldest unanswered operator request, or nil (#328).

  A request is an open gate, an open work-scoped gate, or an open ask -- the
  three things the fleet raises that only a human can close. Never raises,
  for the same reason `last_operator_action_at/0` does not: presence rides
  inside tick composition, and a db hiccup must degrade to "no evidence"
  rather than break the sweep.
  """
  def oldest_unanswered_request do
    [oldest_open("gates"), oldest_open("work_gates"), oldest_open("asks")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.min(stamps, DateTime)
    end
  rescue
    _error -> nil
  end

  defp oldest_open(table) do
    Custode.Repo.one(
      from(row in table,
        where: row.status == "open",
        select: min(row.inserted_at)
      )
    )
    |> to_utc()
  end

  defp gate_touches(since) do
    Custode.Repo.all(
      from(g in Custode.Gates.Gate,
        where: g.status != "open" and g.updated_at >= ^since,
        select: g.updated_at
      )
    )
    |> Enum.map(&to_utc/1)
  end

  defp operator_turns(since) do
    Custode.Repo.all(
      from(f in Custode.Feed.Entry,
        where: f.at >= ^since and not is_nil(fragment("json_extract(?, '$.response')", f.entry)),
        select: f.at
      )
    )
    |> Enum.map(&to_utc/1)
  end

  defp presence_toggles(since) do
    Custode.Repo.all(
      from(f in Custode.Feed.Entry,
        where: f.at >= ^since and f.event == "presence",
        select: f.at
      )
    )
    |> Enum.map(&to_utc/1)
  end

  @doc """
  The newest operator action timestamp across the evidence sources, or nil.
  Never raises: presence rides inside tick composition, and a db hiccup must
  degrade to "no evidence" (away), not break the sweep.
  """
  def last_operator_action_at do
    [latest_gate_touch(), latest_operator_turn(), latest_presence_toggle()]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  rescue
    _error -> nil
  end

  # Any resolved gate row was touched by an operator (approve/reject/answer);
  # open gates are agent-created and do not count.
  defp latest_gate_touch do
    Custode.Repo.one(
      from(g in "gates",
        where: g.status != "open",
        select: max(g.updated_at)
      )
    )
    |> to_utc()
  end

  # Operator-origin turns carry a response (#138) inside the entry JSON;
  # their `at` is when the operator's question was answered -- close enough
  # to when it was asked for a 45-minute window.
  defp latest_operator_turn do
    Custode.Repo.one(
      from(f in "feed_entries",
        where: not is_nil(fragment("json_extract(?, '$.response')", f.entry)),
        select: max(f.at)
      )
    )
    |> to_utc()
  end

  # an explicit toggle is itself a human at the keyboard
  defp latest_presence_toggle do
    Custode.Repo.one(
      from(f in "feed_entries",
        where: f.event == "presence",
        select: max(f.at)
      )
    )
    |> to_utc()
  end

  defp to_utc(nil), do: nil
  defp to_utc(%DateTime{} = at), do: at

  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp to_utc(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp ago(at, now) do
    minutes = div(DateTime.diff(now, at, :second), 60)

    cond do
      minutes < 1 -> "under a minute ago"
      minutes < 60 -> "#{minutes}m ago"
      true -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m ago"
    end
  end
end
