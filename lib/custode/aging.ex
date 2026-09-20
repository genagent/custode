defmodule Custode.Aging do
  @moduledoc """
  Mechanical re-notification for a gate or an ask that has been left open
  (#446).

  A gate notifies once, when it opens. After that its age only moved it up
  the list inside its own kind, and the one escalation path was a paragraph in
  the caretaker's prompt: notice gates older than an hour, escalate each once,
  and remember through a fresh-session journal which ones you already did.
  That is an LLM on a `*/30` sweep standing in for a timer, and the record
  shows how it went: 71 of 403 gates waited over an hour and the worst waited
  13.5.

  The rule here is a timer. An open item re-notifies when its age crosses a
  threshold: 1 h, 4 h, 24 h, then every 24 h (`:aging_thresholds_seconds`).
  That is a backoff and not a nag.

  It is stateless on purpose. There is no "already escalated" column and no
  memory: `Custode.Aging.Job` runs on a fixed interval and passes its own
  `scheduled_at` as the clock, so consecutive runs tile the timeline, and a
  given threshold falls inside exactly one run's `(now - interval, now]`
  window. A run missed because the node was down does not fire late, which is
  correct: open gates are requeued at boot and re-raised on the agent's next
  sweep, which restarts their clock.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Asks.Ask
  alias Custode.Gates.Gate
  alias Custode.Repo

  @default_thresholds_s [3_600, 14_400, 86_400]
  @default_interval_s 600

  @type due :: %{
          kind: :gate | :ask,
          agent_id: String.t(),
          opened_at: DateTime.t(),
          age_s: non_neg_integer(),
          threshold_s: pos_integer(),
          text: String.t()
        }

  @doc "Seconds between runs. Must match the `:aging_cron` line."
  @spec interval_s() :: pos_integer()
  def interval_s, do: Application.get_env(:custode, :aging_interval_seconds, @default_interval_s)

  @doc "The ages, in seconds, at which an open item re-notifies. The last one repeats."
  @spec thresholds_s() :: [pos_integer()]
  def thresholds_s do
    :custode
    |> Application.get_env(:aging_thresholds_seconds, @default_thresholds_s)
    |> Enum.sort()
  end

  @doc """
  The threshold an item of `age_s` crossed within the last `interval_s`, or
  `nil`. Past the last configured threshold, every multiple of it counts.

      iex> Custode.Aging.crossed(3_700, 600)
      3_600

      iex> Custode.Aging.crossed(3_500, 600)
      nil

      iex> Custode.Aging.crossed(2 * 86_400 + 30, 600)
      172_800
  """
  @spec crossed(integer(), pos_integer()) :: pos_integer() | nil
  def crossed(age_s, interval_s) do
    thresholds = thresholds_s()
    last = List.last(thresholds)
    repeating = if last && age_s >= last, do: [div(age_s, last) * last], else: []

    (thresholds ++ repeating)
    |> Enum.filter(&(&1 <= age_s and &1 > age_s - interval_s))
    |> Enum.max(fn -> nil end)
  end

  @doc "Every open gate and open ask that crossed a threshold in the last interval."
  @spec due(DateTime.t(), pos_integer()) :: [due()]
  def due(now \\ DateTime.utc_now(), interval_s \\ interval_s()) do
    gates =
      from(g in Gate, where: g.status == "open", order_by: [asc: g.inserted_at])
      |> Repo.all()
      |> Enum.map(&{:gate, &1.agent_id, &1.inserted_at, &1.detail || &1.kind})

    asks =
      from(a in Ask, where: a.status == "open", order_by: [asc: a.inserted_at])
      |> Repo.all()
      |> Enum.map(&{:ask, &1.agent_id, &1.inserted_at, &1.question})

    for {kind, agent_id, opened_at, text} <- gates ++ asks,
        age_s = DateTime.diff(now, opened_at, :second),
        threshold_s = crossed(age_s, interval_s) do
      %{
        kind: kind,
        agent_id: agent_id,
        opened_at: opened_at,
        age_s: age_s,
        threshold_s: threshold_s,
        text: text
      }
    end
  end

  @doc """
  Re-notify everything that is due. Returns how many notifications went out.

  The desktop notification is held when presence is PINNED away, and only
  then. An inferred away (nothing answered for a while) is exactly the case
  this exists for; a pin is the operator saying not now. ntfy rings either
  way, because the phone is the away channel.
  """
  @spec run(DateTime.t(), pos_integer()) :: non_neg_integer()
  def run(now \\ DateTime.utc_now(), interval_s \\ interval_s()) do
    due = due(now, interval_s)
    desktop? = not pinned_away?(now)

    for item <- due do
      line = "#{noun(item.kind)} has waited #{human(item.threshold_s)}: #{clip(item.text)}"

      Custode.Feed.record(
        %{event: event(item.kind), agent: item.agent_id, summary: line, action: line},
        notify: desktop?
      )
    end

    length(due)
  end

  @doc "A threshold as the operator would say it: `1h`, `4h`, `2d`."
  @spec human(pos_integer()) :: String.t()
  def human(seconds) when seconds >= 86_400 and rem(seconds, 86_400) == 0,
    do: "#{div(seconds, 86_400)}d"

  def human(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h"
  def human(seconds), do: "#{div(seconds, 60)}m"

  defp pinned_away?(now) do
    match?({:away, _at, {:pinned, :away}}, Custode.Presence.explain(now))
  end

  defp event(:gate), do: "gate_aging"
  defp event(:ask), do: "ask_aging"

  defp noun(:gate), do: "a gate"
  defp noun(:ask), do: "a question"

  defp clip(text), do: text |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)
end
