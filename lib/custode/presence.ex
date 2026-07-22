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
      {:present, at} ->
        "\n## Operator presence\noperator: PRESENT (last action #{ago(at, now)})\n"

      {:away, nil} ->
        "\n## Operator presence\noperator: AWAY (no recorded actions yet)\n"

      {:away, at} ->
        "\n## Operator presence\noperator: AWAY (last action #{ago(at, now)})\n"
    end
  end

  @doc """
  The newest operator action timestamp across the evidence sources, or nil.
  Never raises: presence rides inside tick composition, and a db hiccup must
  degrade to "no evidence" (away), not break the sweep.
  """
  def last_operator_action_at do
    [latest_gate_touch(), latest_operator_turn()]
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
