defmodule Custode.ObanEngineTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Custode.ObanEngine

  defmodule Repo do
    use Ecto.Repo, otp_app: :custode, adapter: Ecto.Adapters.SQLite3
  end

  test "application uses the retrying engine without a SQLite table prefix" do
    assert %Oban.Config{engine: ObanEngine, prefix: nil} = Oban.config()
  end

  test "retries only busy Exqlite errors with bounded backoff" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    operation = fn ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

      if attempt < 2 do
        raise Exqlite.Error, message: "Database busy"
      else
        :acknowledged
      end
    end

    assert :acknowledged =
             ObanEngine.retry_busy(operation,
               delays: [10, 20, 40],
               sleep: &send(self(), {:slept, &1})
             )

    assert_receive {:slept, 10}
    assert_receive {:slept, 20}
    assert Agent.get(attempts, & &1) == 3
  end

  test "does not retry unrelated database failures" do
    assert_raise Exqlite.Error, "malformed database schema", fn ->
      ObanEngine.retry_busy(
        fn -> raise Exqlite.Error, message: "malformed database schema" end,
        delays: [0]
      )
    end
  end

  test "raises the busy error after retries are exhausted" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert_raise Exqlite.Error, "Database busy", fn ->
        ObanEngine.retry_busy(
          fn -> raise Exqlite.Error, message: "Database busy" end,
          delays: [0, 0],
          sleep: fn _ -> :ok end
        )
      end
    end)
  end

  test "concurrent job acknowledgements complete after a SQLite write lock clears" do
    path = Path.join(System.tmp_dir!(), "custode-oban-ack-#{Ecto.UUID.generate()}.db")

    start_supervised!(
      {Repo, database: path, pool_size: 1, busy_timeout: 0, log: false, name: Repo}
    )

    attempted_at = DateTime.utc_now()

    Repo.query!("""
    CREATE TABLE oban_jobs (
      id INTEGER PRIMARY KEY,
      state TEXT NOT NULL,
      attempted_at TEXT,
      completed_at TEXT
    )
    """)

    Repo.insert_all(Oban.Job, [
      %{id: 1, state: "executing", attempted_at: attempted_at},
      %{id: 2, state: "executing", attempted_at: attempted_at}
    ])

    {:ok, lock} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(lock, "BEGIN IMMEDIATE")

    handler = "oban-ack-retry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:custode, :oban, :ack_retry],
      &__MODULE__.handle_retry/4,
      parent
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Exqlite.Sqlite3.close(lock)
      File.rm(path)
    end)

    previous = Application.get_env(:custode, :oban_ack_retry_delays)
    Application.put_env(:custode, :oban_ack_retry_delays, [10, 20, 40, 80, 160])

    on_exit(fn ->
      if previous do
        Application.put_env(:custode, :oban_ack_retry_delays, previous)
      else
        Application.delete_env(:custode, :oban_ack_retry_delays)
      end
    end)

    conf = %Oban.Config{repo: Repo, prefix: nil}

    jobs =
      Oban.Job
      |> select([job], map(job, [:id, :state, :attempted_at]))
      |> order_by([job], asc: job.id)
      |> Repo.all()
      |> Enum.map(&struct!(Oban.Job, &1))

    tasks =
      for job <- jobs do
        Task.async(fn -> ObanEngine.complete_job(conf, job) end)
      end

    assert_receive {:ack_retry, %{attempt: 1}, %{operation: :complete_job}}, 1_000
    assert_receive {:ack_retry, %{attempt: 1}, %{operation: :complete_job}}, 1_000

    :ok = Exqlite.Sqlite3.execute(lock, "COMMIT")

    assert Enum.map(tasks, &Task.await(&1, 1_000)) == [:ok, :ok]

    assert %{rows: [["completed"], ["completed"]]} =
             Repo.query!("SELECT state FROM oban_jobs ORDER BY id")
  end

  @doc false
  def handle_retry(_event, measurements, metadata, recipient) do
    send(recipient, {:ack_retry, measurements, metadata})
  end
end
