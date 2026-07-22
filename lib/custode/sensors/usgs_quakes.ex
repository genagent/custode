defmodule Custode.Sensors.UsgsQuakes do
  @moduledoc """
  The first non-development sensor: polls a USGS earthquake GeoJSON summary
  feed for events at or above the configured magnitude. New events wake the
  quake_watch routine with a note (tsunami-flagged events called out); the
  fetch sits behind the `:quake_fetcher` config seam.

  Args: `feed` (USGS summary URL) and `min_magnitude` (default 4.5).
  """

  use Custode.Sensor

  @default_feed "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson"

  @impl Custode.Sensor
  def fetch(args) do
    feed = Map.get(args, "feed", @default_feed)
    min_magnitude = Map.get(args, "min_magnitude", 4.5)

    with {:ok, %{"features" => features}} <- fetcher().fetch(feed) do
      quakes =
        features
        |> Enum.map(&quake/1)
        |> Enum.filter(&(&1.magnitude != nil and &1.magnitude >= min_magnitude))

      {:ok, quakes}
    end
  end

  @impl Custode.Sensor
  def key(quake), do: quake.id

  @impl Custode.Sensor
  def note(new_quakes, _args) do
    lines =
      for quake <- Enum.sort_by(new_quakes, & &1.magnitude, :desc) do
        tsunami = if quake.tsunami, do: " TSUNAMI FLAG SET --", else: ""
        "- M#{quake.magnitude} #{quake.place} at #{quake.at} UTC --#{tsunami} #{quake.url}"
      end

    """
    Sensor: #{length(new_quakes)} new earthquake(s) at or above threshold.

    #{Enum.join(lines, "\n")}

    Judge per your standing orders: journal each, escalate only what
    warrants a human.
    """
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

  defp fetcher do
    Application.get_env(:custode, :quake_fetcher, Custode.Sensors.UsgsQuakes.Fetcher)
  end
end

defmodule Custode.Sensors.UsgsQuakes.FetcherBehaviour do
  @moduledoc "The `:quake_fetcher` contract (#92): GeoJSON summary URL in, decoded body out."

  @callback fetch(url :: String.t()) :: {:ok, map()} | {:error, term()}
end

defmodule Custode.Sensors.UsgsQuakes.Fetcher do
  @moduledoc "The real USGS fetch: GeoJSON summary URL in, decoded body out."

  @behaviour Custode.Sensors.UsgsQuakes.FetcherBehaviour

  @impl true
  def fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
