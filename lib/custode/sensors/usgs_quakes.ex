defmodule Custode.Sensors.UsgsQuakes do
  @moduledoc """
  The first non-development sensor: polls a USGS earthquake GeoJSON summary
  feed and drops an inbox note when NEW events at or above the configured
  magnitude appear. Same shape as every sensor -- mechanical detection,
  memory-diffed (`sensor:<id>` / `"seen"` event ids, replaced wholesale so
  events age out with the feed window), judgment left to the routine the
  note wakes.

  Args (via the crontab entry): `feed` (USGS summary feed URL), and
  `min_magnitude` (default 4.5). The fetch sits behind the
  `:quake_fetcher` config seam.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  @default_feed "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    sensor_id = Map.fetch!(args, "sensor_id")
    notify = Map.fetch!(args, "notify")
    feed = Map.get(args, "feed", @default_feed)
    min_magnitude = Map.get(args, "min_magnitude", 4.5)

    case fetcher().fetch(feed) do
      {:ok, %{"features" => features}} ->
        features
        |> Enum.map(&quake/1)
        |> Enum.filter(&(&1.magnitude != nil and &1.magnitude >= min_magnitude))
        |> diff_and_report(sensor_id, notify)

      {:error, reason} ->
        Custode.Feed.record(%{
          event: "sensor",
          agent: notify,
          summary: "#{sensor_id}: feed fetch failed (#{inspect(reason)}), will retry"
        })

        :ok
    end
  end

  defp quake(feature) do
    properties = feature["properties"] || %{}

    %{
      id: feature["id"],
      magnitude: properties["mag"],
      place: properties["place"] || "unknown location",
      at: format_time(properties["time"]),
      tsunami: properties["tsunami"] == 1,
      url: properties["url"]
    }
  end

  defp format_time(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_time(_missing), do: "?"

  defp diff_and_report(quakes, sensor_id, notify) do
    memory_key = "sensor:" <> sensor_id
    current_ids = MapSet.new(quakes, & &1.id)

    seen =
      case Custode.Memory.recall(memory_key, "seen") do
        {:ok, json} -> json |> Jason.decode!() |> MapSet.new()
        :error -> MapSet.new()
      end

    :ok = Custode.Memory.remember(memory_key, "seen", Jason.encode!(MapSet.to_list(current_ids)))

    case Enum.filter(quakes, &(not MapSet.member?(seen, &1.id))) do
      [] ->
        Custode.Feed.record(%{
          event: "sensor",
          agent: notify,
          summary: "#{sensor_id}: no new events (#{MapSet.size(current_ids)} in window)"
        })

        :ok

      new_quakes ->
        note!(sensor_id, notify, new_quakes)
    end
  end

  defp note!(sensor_id, notify, new_quakes) do
    lines =
      for quake <- Enum.sort_by(new_quakes, & &1.magnitude, :desc) do
        tsunami = if quake.tsunami, do: " TSUNAMI FLAG SET --", else: ""
        "- M#{quake.magnitude} #{quake.place} at #{quake.at} UTC --#{tsunami} #{quake.url}"
      end

    {:ok, _path} =
      Custode.Inbox.drop(
        notify,
        "sensor-#{sensor_id}-#{System.unique_integer([:positive])}.md",
        """
        Sensor #{sensor_id}: #{length(new_quakes)} new earthquake(s) at or above threshold.

        #{Enum.join(lines, "\n")}

        Judge per your standing orders: journal each, escalate only what
        warrants a human.
        """
      )

    Custode.Feed.record(%{
      event: "sensor",
      agent: notify,
      summary: "#{sensor_id}: #{length(new_quakes)} new event(s), note dropped"
    })

    :ok
  end

  defp fetcher do
    Application.get_env(:custode, :quake_fetcher, Custode.Sensors.UsgsQuakes.Fetcher)
  end
end

defmodule Custode.Sensors.UsgsQuakes.Fetcher do
  @moduledoc "The real USGS fetch: GeoJSON summary URL in, decoded body out."

  def fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
