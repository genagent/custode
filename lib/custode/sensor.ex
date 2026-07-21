defmodule Custode.Sensor do
  @moduledoc """
  The sensor behaviour (issue #64): the mechanical-detection pattern all
  sensors share, named once. A sensor is an Oban worker on the `:sensors`
  queue that fetches through a seam, normalizes to keyed items, diffs
  against its own `sensor:<id>` memory (seen-set replaced wholesale, so
  items age out with the source window), drops ONE inbox note through the
  funnel for genuinely-new items, feeds a status line either way, and
  skips quietly on fetch errors. Cheap sensor, expensive brain.

  A sensor implements three decisions:

      defmodule Custode.Sensors.Whatever do
        use Custode.Sensor                     # or baseline: :silent
        @impl true
        def fetch(args), do: {:ok, [item]}     # normalized, pre-filtered
        @impl true
        def key(item), do: item.id             # identity for the diff
        @impl true
        def note(new_items, args), do: "..."   # the markdown body
      end

  `baseline: :silent` (ContributorSearch) records the first run without a
  note -- pre-existing state is not news. The default `:report`
  (CiStatus, UsgsQuakes) notes immediately: a currently-failing PR or a
  fresh quake is actionable regardless of history.
  """

  @doc "Fetch and normalize current items (already filtered to relevance)."
  @callback fetch(args :: map()) :: {:ok, [map()]} | {:error, term()}

  @doc "The item's identity for the seen-set diff."
  @callback key(item :: map()) :: String.t()

  @doc "The inbox note body for genuinely-new items."
  @callback note(new_items :: [map()], args :: map()) :: String.t()

  defmacro __using__(opts) do
    baseline = Keyword.get(opts, :baseline, :report)

    quote do
      use Oban.Worker, queue: :sensors, max_attempts: 1

      @behaviour Custode.Sensor

      @impl Oban.Worker
      def perform(%Oban.Job{args: args}) do
        Custode.Sensor.run(__MODULE__, unquote(baseline), args)
      end
    end
  end

  @doc false
  def run(module, baseline, args) do
    sensor_id = Map.fetch!(args, "sensor_id")
    notify = Map.fetch!(args, "notify")

    case module.fetch(args) do
      {:ok, items} ->
        diff(module, baseline, sensor_id, notify, items, args)

      {:error, reason} ->
        feed(sensor_id, notify, "#{sensor_id}: fetch failed (#{inspect(reason)}), will retry")
    end
  end

  defp diff(module, baseline, sensor_id, notify, items, args) do
    memory_key = "sensor:" <> sensor_id
    current_keys = MapSet.new(items, &module.key/1)

    case Custode.Memory.recall(memory_key, "seen") do
      :error when baseline == :silent ->
        remember!(memory_key, current_keys)

        feed(
          sensor_id,
          notify,
          "#{sensor_id}: baseline recorded (#{MapSet.size(current_keys)} known items)"
        )

      recalled ->
        seen =
          case recalled do
            {:ok, json} -> json |> Jason.decode!() |> MapSet.new()
            :error -> MapSet.new()
          end

        remember!(memory_key, current_keys)
        report(module, sensor_id, notify, args, current_keys, reject_seen(module, items, seen))
    end
  end

  defp reject_seen(module, items, seen) do
    Enum.reject(items, &MapSet.member?(seen, module.key(&1)))
  end

  defp report(_module, sensor_id, notify, _args, current_keys, []) do
    feed(sensor_id, notify, "#{sensor_id}: nothing new (#{MapSet.size(current_keys)} in window)")
  end

  defp report(module, sensor_id, notify, args, _current_keys, new_items) do
    {:ok, _path} =
      Custode.Inbox.drop(
        notify,
        "sensor-#{sensor_id}-#{System.unique_integer([:positive])}.md",
        module.note(new_items, args)
      )

    feed(sensor_id, notify, "#{sensor_id}: #{length(new_items)} new item(s), note dropped")
  end

  defp remember!(memory_key, current_keys) do
    :ok = Custode.Memory.remember(memory_key, "seen", Jason.encode!(MapSet.to_list(current_keys)))
  end

  defp feed(sensor_id, notify, summary) do
    Custode.Feed.record(%{event: "sensor", agent: notify, sensor_id: sensor_id, summary: summary})
    :ok
  end
end
