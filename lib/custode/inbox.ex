defmodule Custode.Inbox do
  @moduledoc """
  The single funnel for programmatic inbox notes -- the console's `note/1`,
  one-shot job reports, gate restart notices, and sensors all drop through
  here. Dropping a note does two things:

    1. writes the note file into the routine's `inbox/`
    2. fires the EVENT KICKOFF: for a routine with `on_note: :beat` (the
       default), a debounced Tick is scheduled (~20s out, Oban-unique per
       agent), so a burst of notes wakes the agent exactly once, shortly
       after the last one lands

  That closes the sensor loop (mechanical detection -> note -> beat -> LLM
  judgment) and makes job reports and restart notices wake their agents
  promptly instead of at the next cron boundary. Notes dropped by hand
  (files created outside the BEAM) are not detected -- beat manually, or
  wait for the schedule.
  """

  alias ObanClaude.Agent.Tick

  @debounce_seconds 20
  @unique_period 120

  @doc """
  Drop a note into a routine's inbox and fire the event kickoff.

  `routine_or_id` is a routine map or id; unknown ids write nothing and
  return `{:error, :unknown_routine}`. Returns `{:ok, path}`.
  """
  def drop(routine_or_id, name, content) do
    with {:ok, routine} <- fetch(routine_or_id) do
      path = routine.workspace |> Path.expand() |> Path.join("inbox") |> Path.join(name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      maybe_beat(routine)
      {:ok, path}
    end
  end

  @doc """
  Schedule the debounced event beat for a routine (public so callers that
  write files themselves -- or want to wake an agent without a note -- can
  reuse the debounce).
  """
  def maybe_beat(%{on_note: :ignore}), do: :ok

  def maybe_beat(routine) do
    changeset =
      Tick.new(
        Custode.Routine.tick_args(routine),
        queue: :ticks,
        schedule_in: @debounce_seconds,
        unique: [
          period: @unique_period,
          fields: [:worker, :queue, :args],
          keys: [:agent_id],
          states: [:available, :scheduled]
        ]
      )

    case Oban.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("event beat insert failed for #{routine.id}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Drop a note into an explicit inbox DIRECTORY (the one-shot job report path,
  which carries a `report_inbox` dir rather than a routine). If the directory
  belongs to a configured routine's workspace, the event kickoff fires too.
  """
  def drop_path(inbox_dir, name, content) do
    inbox_dir = Path.expand(inbox_dir)
    File.mkdir_p!(inbox_dir)
    path = Path.join(inbox_dir, name)
    File.write!(path, content)

    case owner_of(inbox_dir) do
      nil -> :ok
      routine -> maybe_beat(routine)
    end

    {:ok, path}
  end

  defp owner_of(inbox_dir) do
    Enum.find(Custode.Routine.all(), fn routine ->
      routine.workspace |> Path.expand() |> Path.join("inbox") == inbox_dir
    end)
  end

  defp fetch(%{id: _id} = routine), do: {:ok, routine}

  defp fetch(id) when is_binary(id) do
    case Custode.Routine.get(id) do
      nil -> {:error, :unknown_routine}
      routine -> {:ok, routine}
    end
  end
end
