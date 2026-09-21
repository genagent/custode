defmodule Custode.Drain do
  @moduledoc """
  Close queue admission before a drain reads active work or hands off its wait.

  Oban delivers pause notifications asynchronously. A successful notification
  is followed by checking each local producer until it confirms the pause.
  """

  @pause_timeout 5_000
  @pause_poll 10

  @spec pause(keyword()) :: {:ok, [atom() | String.t()]} | {:error, String.t()}
  def pause(opts \\ []) do
    queues = Keyword.get_lazy(opts, :queues, &configured_queues/0)
    pause = Keyword.get(opts, :pause, &Oban.pause_queue(queue: &1))
    check = Keyword.get(opts, :check_queue, &Oban.check_queue(queue: &1))

    timeout = Keyword.get(opts, :pause_timeout, @pause_timeout)

    with {:ok, required} <- prepare_ticks(queues),
         :ok <- request_pauses(queues, pause),
         :ok <- confirm_paused(queues, required, check, timeout) do
      {:ok, queues}
    end
  end

  defp configured_queues do
    configured = Keyword.keys(Oban.config().queues)
    requested = Application.get_env(:custode, :oban_queues, ticks: 1) |> Keyword.keys()

    # Ticks start dynamically after the MCP probe. Include any other queue
    # started at runtime too, without waiting on producers while discovering it.
    running =
      Oban.Registry.select([
        {{{Oban, {:producer, :"$1"}}, :_, :_}, [], [:"$1"]}
      ])

    Enum.uniq_by(configured ++ requested ++ running, &to_string/1)
  end

  defp request_pauses(queues, pause) do
    Enum.reduce_while(queues, :ok, fn queue, :ok ->
      case pause.(queue) do
        {:error, reason} ->
          {:halt, {:error, "could not pause queue #{queue}: #{inspect(reason)}"}}

        _sent ->
          {:cont, :ok}
      end
    end)
  end

  # Reserve the boot-owned queue paused before acknowledging drain. A later
  # MCP probe start is then a duplicate, which Oban does not use to resume or
  # replace a running queue. Waiting for its producer also covers the race
  # where the probe's unpaused start reached Oban first.
  defp prepare_ticks(queues) do
    limit = Application.get_env(:custode, :oban_queues, ticks: 1) |> Keyword.get(:ticks)

    if limit && Enum.any?(queues, &(to_string(&1) == "ticks")) do
      case Oban.start_queue(queue: :ticks, limit: limit, paused: true) do
        :ok -> {:ok, ["ticks"]}
        {:error, reason} -> {:error, "could not reserve paused ticks queue: #{inspect(reason)}"}
      end
    else
      {:ok, []}
    end
  end

  defp confirm_paused([], _required, _check, _timeout), do: :ok

  defp confirm_paused(queues, required, check, timeout) do
    # Oban.check_queue/1 has its own blocking call timeout. Bound the whole
    # acknowledgment task, including any individual unresponsive producer.
    task =
      Task.Supervisor.async_nolink(Custode.TaskSupervisor, fn ->
        await_paused(queues, required, check)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "queue pause confirmation failed: #{inspect(reason)}"}
      nil -> {:error, "queues did not confirm pause: #{Enum.join(queues, ", ")}"}
    end
  end

  defp await_paused(queues, required, check) do
    case pending_queues(queues, required, check) do
      {:ok, []} ->
        :ok

      {:ok, pending} ->
        Process.sleep(@pause_poll)
        await_paused(pending, required, check)

      {:error, _reason} = error ->
        error
    end
  end

  defp pending_queues(queues, required, check) do
    Enum.reduce_while(queues, {:ok, []}, fn queue, {:ok, pending} ->
      case check.(queue) do
        %{paused: true} ->
          {:cont, {:ok, pending}}

        %{paused: false} ->
          {:cont, {:ok, [queue | pending]}}

        nil ->
          # Oban also returns nil when a producer's state read exits. A
          # registered producer is not proof of closed admission in that case.
          missing_queue(queue, required, pending)

        {:error, reason} ->
          {:halt, {:error, "could not confirm pause for queue #{queue}: #{inspect(reason)}"}}
      end
    end)
  end

  defp missing_queue(queue, required, pending) do
    cond do
      Oban.Registry.whereis(Oban, {:producer, to_string(queue)}) ->
        {:halt, {:error, "could not confirm pause for queue #{queue}"}}

      to_string(queue) in required ->
        {:cont, {:ok, [queue | pending]}}

      true ->
        {:cont, {:ok, pending}}
    end
  end
end
