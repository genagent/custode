defmodule Custode.Presence do
  @moduledoc """
  Operator presence (#141 slice 1): is a human around right now?

  The signal is INFERRED from evidence the db already holds -- the newest
  operator action is the newest of:

    * a gate resolution (approve/reject/answer all touch `gates.updated_at`)
    * an operator-origin turn (the feed entries #138 marks with a response,
      i.e. a prompt the operator sent and got answered)

  with an EXPLICIT override on top: `Application.put_env(:custode,
  :presence_override, :present | :away)` pins the answer either way (the
  future away/back tool and dashboard toggle set this; `nil` restores
  inference). Present means an action within `:presence_window_minutes`
  (default 45).

  Why it matters mechanically: a gate PARKS the proposing agent, so an agent
  that proposes into an empty room wastes its whole night parked. The
  rendered context line lets sweeps choose night-shaped work instead (#141
  slice 2 teaches the roles to read it).

  Rendered into every tick's system prompt at fire time -- #121/#142 make
  that live, so presence flips reach the very next sweep with no restart.
  """

  import Ecto.Query, only: [from: 2]

  @doc "The presence reading: `{:present, last_action_at}` | `{:away, last_action_at | nil}`."
  def status(now \\ DateTime.utc_now()) do
    case Application.get_env(:custode, :presence_override) do
      :present ->
        {:present, last_operator_action_at()}

      :away ->
        {:away, last_operator_action_at()}

      _infer ->
        last = last_operator_action_at()
        window = Application.get_env(:custode, :presence_window_minutes, 45) * 60

        if last && DateTime.diff(now, last, :second) <= window,
          do: {:present, last},
          else: {:away, last}
    end
  end

  @doc """
  The prompt context line for a tick (one line; roles read it, slice 2).
  """
  def render(now \\ DateTime.utc_now()) do
    case status(now) do
      {:present, nil} ->
        "\n## Operator presence\noperator: PRESENT (pinned; no recorded actions yet)\n"

      {:present, at} ->
        "\n## Operator presence\noperator: PRESENT (last action #{ago(at, now)})\n"

      {:away, nil} ->
        "\n## Operator presence\noperator: AWAY (no recorded actions yet)\n"

      {:away, at} ->
        "\n## Operator presence\noperator: AWAY (last action #{ago(at, now)})\n"
    end
  end

  @doc """
  The explicit toggle (#141): `:away` pins away, `:present` pins present,
  `:auto` restores inference. Every toggle is recorded as a feed event that
  itself counts as an operator action -- so `back` (set `:auto`) reads
  present immediately and then expires naturally with the window, instead
  of needing a pin that never lapses.
  """
  def set(mode) when mode in [:present, :away, :auto] do
    Application.put_env(:custode, :presence_override, if(mode == :auto, do: nil, else: mode))

    Custode.Feed.record(%{
      event: "presence",
      agent: "operator",
      summary: "operator marked #{mode}"
    })

    status()
  end

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
