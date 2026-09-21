defmodule Custode.DrainAdmissionTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query

  defmodule FollowupWorker do
    use Oban.Worker, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: args, queue: queue}) do
      owner = args["owner"] |> String.to_charlist() |> :erlang.list_to_pid()
      send(owner, {:worker_started, args["step"], self()})

      if args["step"] == "first" do
        receive do
          :finish ->
            args |> Map.put("step", "second") |> new(queue: queue) |> Oban.insert!()
            :ok
        after
          2_000 -> {:error, :fixture_timeout}
        end
      else
        :ok
      end
    end
  end

  setup do
    put_env!(:oban_queues, [])
    queue = uid("drain-admission")
    :ok = Oban.start_queue(queue: queue, limit: 1, paused: true)
    await_queue(queue, &match?(%{paused: true}, &1))

    on_exit(fn ->
      Oban.stop_queue(queue: queue)
      await_queue(queue, &is_nil/1)
      Custode.Repo.delete_all(from(job in Oban.Job, where: job.queue == ^queue))
    end)

    %{queue: queue}
  end

  test "a dynamically started producer confirms pause before a successor is enqueued", %{
    queue: queue
  } do
    parent = self()

    %{"owner" => self() |> :erlang.pid_to_list() |> to_string(), "step" => "first"}
    |> FollowupWorker.new(queue: queue)
    |> Oban.insert!()

    :ok = Oban.resume_queue(queue: queue)
    assert_receive {:worker_started, "first", worker}, 1_000

    put_env!(:drain_fun, fn opts ->
      assert %{paused: true} = Oban.check_queue(queue: queue)
      Custode.drain(Keyword.put(opts, :stop, fn -> send(parent, :stopped) end))
    end)

    assert 1 = Custode.start_drain(1_000, executing: fn -> executing(queue) end, poll: 1)
    assert %{paused: true} = Oban.check_queue(queue: queue)
    send(worker, :finish)
    assert_receive :stopped, 2_000

    [successor] =
      Custode.Repo.all(
        from(job in Oban.Job,
          where: job.queue == ^queue,
          where: fragment("json_extract(?, '$.step')", job.args) == "second"
        )
      )

    assert successor.state == "available"
    assert %{paused: true} = Oban.check_queue(queue: queue)
    refute_received {:worker_started, "second", _worker}
  end

  test "a missing state response from a live producer fails closed", %{queue: queue} do
    parent = self()

    assert {:error, message} =
             Custode.drain(
               queues: [queue],
               check_queue: fn _queue -> nil end,
               executing: fn -> send(parent, :active_work_read) end,
               stop: fn -> send(parent, :stopped) end
             )

    assert message == "could not confirm pause for queue #{queue}"
    refute_received :active_work_read
    refute_received :stopped
  end

  test "a delayed probe start cannot reopen ticks after drain" do
    put_env!(:oban_queues, ticks: 1)
    assert Oban.check_queue(queue: :ticks) == nil
    parent = self()

    on_exit(fn ->
      Oban.stop_queue(queue: :ticks)
      await_queue(:ticks, &is_nil/1)
      Custode.Repo.delete_all(from(job in Oban.Job, where: job.queue == "ticks"))
    end)

    assert :ok =
             Custode.drain(
               executing: fn ->
                 assert %{paused: true} = Oban.check_queue(queue: :ticks)
                 []
               end,
               stop: fn -> send(parent, :stopped) end
             )

    assert_received :stopped
    producer = Oban.Registry.whereis(Oban, {:producer, "ticks"})
    monitor = Process.monitor(producer)

    # This is the exact queue-start operation performed by the delayed probe.
    :ok = Oban.start_queue(queue: :ticks, limit: 1)

    job =
      %{"owner" => self() |> :erlang.pid_to_list() |> to_string(), "step" => "second"}
      |> FollowupWorker.new(queue: :ticks)
      |> Oban.insert!()

    # Allow both start and insert notifications to reach the real producer.
    refute_receive {:worker_started, "second", _worker}, 100
    refute_received {:DOWN, ^monitor, :process, ^producer, _reason}
    Process.demonitor(monitor, [:flush])
    assert Oban.Registry.whereis(Oban, {:producer, "ticks"}) == producer
    assert %{paused: true} = Oban.check_queue(queue: :ticks)
    assert Custode.Repo.get!(Oban.Job, job.id).state == "available"
  end

  test "pause timeout bounds a blocked producer check and cleans up its waiter", %{queue: queue} do
    producer = Oban.Registry.whereis(Oban, {:producer, queue})
    :ok = :sys.suspend(producer)
    on_exit(fn -> :sys.resume(producer) end)
    parent = self()
    started = System.monotonic_time(:millisecond)

    assert {:error, "queues did not confirm pause: " <> ^queue} =
             Custode.drain(
               queues: [queue],
               check_queue: fn queue ->
                 send(parent, {:checking, self()})
                 Oban.check_queue(queue: queue)
               end,
               pause_timeout: 50,
               executing: fn -> send(parent, :active_work_read) end,
               stop: fn -> send(parent, :stopped) end
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_received {:checking, waiter}
    refute Process.alive?(waiter)
    refute_received :active_work_read
    refute_received :stopped
    assert Process.alive?(producer)
    :ok = :sys.resume(producer)
  end

  defp executing(queue) do
    Custode.Repo.all(
      from(job in Oban.Job,
        where: job.queue == ^queue and job.state == "executing",
        select: %{id: job.id, queue: job.queue, worker: job.worker}
      )
    )
  end

  defp await_queue(queue, predicate, attempts \\ 200)
  defp await_queue(_queue, _predicate, 0), do: flunk("queue did not reach the expected state")

  defp await_queue(queue, predicate, attempts) do
    if predicate.(Oban.check_queue(queue: queue)) do
      :ok
    else
      Process.sleep(10)
      await_queue(queue, predicate, attempts - 1)
    end
  end
end
