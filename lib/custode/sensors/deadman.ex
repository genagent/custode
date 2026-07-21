defmodule Custode.Sensors.Deadman do
  @moduledoc """
  The mechanical half of dead-man alerting (#3): a sensor that watches the
  sensors. Every sensor run feeds a status line stamped with its
  sensor_id; this one checks each configured sensor's last stamp against
  its expected cadence and, when a sensor has been silent for more than
  twice its interval (plus grace), drops a note to the meta-agent -- whose
  SILENT SENSORS standing orders escalate to a human. Silence is the one
  failure nothing else detects.

  A sensor that has NEVER fed is skipped (fresh boots would false-alarm);
  the tripwire arms after first light. Seen-keys include the date, so a
  still-dead sensor re-notes daily rather than every poll.
  """

  use Custode.Sensor

  @impl Custode.Sensor
  def fetch(args) do
    own_id = Map.fetch!(args, "sensor_id")
    now = DateTime.utc_now()

    overdue =
      for sensor <- Custode.Routine.sensors(),
          sensor.id != own_id,
          last = last_seen(sensor.id),
          last != nil,
          expected = interval_minutes(sensor.cron),
          silent = div(DateTime.diff(now, last), 60),
          silent > expected * 2 + 5 do
        %{id: sensor.id, silent_minutes: silent, expected_minutes: expected}
      end

    {:ok, overdue}
  end

  @impl Custode.Sensor
  def key(item), do: "#{item.id}:#{Date.utc_today()}"

  @impl Custode.Sensor
  def note(overdue, _args) do
    lines =
      for item <- overdue do
        "- #{item.id}: silent #{item.silent_minutes}m (expected every ~#{item.expected_minutes}m)"
      end

    """
    Sensor deadman: #{length(overdue)} sensor(s) have gone silent.

    #{Enum.join(lines, "\n")}

    Per your SILENT SENSORS standing orders: journal this and raise it
    with ask_user -- a dead sensor means its whole detection channel is
    dark until a human looks.
    """
  end

  @doc false
  def last_seen(sensor_id) do
    import Ecto.Query, only: [from: 2]

    Custode.Repo.one(
      from(f in Custode.Feed.Entry,
        where:
          f.event == "sensor" and
            fragment("json_extract(?, '$.sensor_id')", f.entry) == ^sensor_id,
        select: max(f.at)
      )
    )
  end

  @doc false
  def interval_minutes("@daily"), do: 1_440
  def interval_minutes("@hourly"), do: 60

  def interval_minutes("*/" <> rest) do
    rest |> String.split(" ", parts: 2) |> hd() |> String.to_integer()
  end

  def interval_minutes(_cron), do: 60
end
