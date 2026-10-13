defmodule AdapterProof.AdapterTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AdapterProof.{Attempt, Fixture, Journal, Lead, Project, Repo, Runtime, Sink, Turn, Worker}

  setup context do
    directory = Path.join(System.tmp_dir!(), "custode-adapter-proof-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    repo_opts = [
      database: Path.join(directory, "proof.sqlite3"),
      pool_size: 1,
      busy_timeout: 5_000
    ]

    start_supervised!({Repo, repo_opts})

    Ecto.Migrator.up(Repo, 20_261_013_223_913, AdapterProof.Repo.Migrations.CreateProofJournal,
      log: false
    )

    start_supervised!(
      {Oban,
       name: ProofOban,
       repo: Repo,
       engine: Oban.Engines.Lite,
       notifier: Oban.Notifiers.Isolated,
       peer: false,
       plugins: [],
       queues: [],
       testing: :manual}
    )

    start_supervised!({Task.Supervisor, name: ProofTasks})

    fixture =
      start_supervised!(
        {Fixture, observer: self(), dir: directory, escape: context[:escape] || false}
      )

    sink =
      start_supervised!(%{id: Sink, start: {Sink, :start_link, [fixture]}, restart: :temporary})

    project = Journal.create_project()
    name = "proof-lead-#{Ecto.UUID.generate()}"

    {:ok, _} =
      GenAgent.start_agent(Lead,
        name: name,
        backend: AdapterProof.Backend,
        project: project.id,
        backend_opts: [
          sink: sink,
          fixture: fixture,
          launch_spec: Fixture.spec(fixture)
        ]
      )

    Runtime.bind(project.id, name, sink, fixture)
    turn = Journal.enqueue(project.id, Fixture.spec(fixture))
    successor = Journal.enqueue(project.id, Fixture.spec(fixture))

    on_exit(fn ->
      GenAgent.stop(name)
      File.rm_rf!(directory)
    end)

    {:ok,
     %{
       project: project,
       turn: turn,
       successor: successor,
       fixture: fixture,
       lead: name,
       sink: sink,
       directory: directory,
       repo_opts: repo_opts
     }}
  end

  test "A1 pause before admission holds scheduled and direct work across storage restart", c do
    Fixture.gate(c.fixture, [:before_admission])
    worker = deliver(c.turn)
    assert_receive {:barrier, :before_admission, pid, _}
    assert pid == worker.pid
    Journal.pause(c.project.id, true)
    direct = Journal.enqueue(c.project.id, Fixture.spec(c.fixture))
    stop_supervised(Repo)
    start_supervised!({Repo, c.repo_opts})
    assert Journal.project(c.project.id).paused
    send(pid, {:release, :before_admission})
    assert Task.await(worker).snoozed == 1
    assert Journal.admit(direct.id) == {:ok, :held}
    assert Journal.admit(c.successor.id) == {:ok, :held}
    assert Repo.aggregate(Attempt, :count) == 0
    assert launches(c) == 0
    evidence(c, "A1")
  end

  test "fixture guard rejects real executables and changed fixture content before launch", c do
    assert_raise RuntimeError, "live executable forbidden", fn ->
      AdapterProof.GuardedRunner.stream_lines("/usr/bin/claude", [], [], 100)
    end

    spec = put_in(Fixture.spec(c.fixture), ["provider", "binary_sha256"], "wrong")
    prompt = Jason.encode!(%{spec: spec})

    assert_raise RuntimeError, "fixture executable changed since capture", fn ->
      AdapterProof.GuardedRunner.stream_lines(
        Path.expand("test/fixtures/cli.py"),
        [prompt],
        [],
        100
      )
    end

    assert launches(c) == 0
  end

  test "A2 admission wins before pause; its single permit finishes and successor stays held", c do
    Fixture.gate(c.fixture, [:admitted])
    worker = deliver(c.turn)
    assert_receive {:barrier, :admitted, pid, attempt}
    Journal.pause(c.project.id, true)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert launches(c) == 0
    assert Task.await(deliver(c.turn)).success == 1
    assert Journal.attempt(attempt.id).phase == "admitted"
    assert launches(c) == 0
    send(pid, {:release, :admitted})
    started()
    finish(c, attempt)
    assert Task.await(worker).success == 1
    assert Journal.project(c.project.id).paused
    assert Journal.admit(c.successor.id) == {:ok, :held}
    assert launches(c) == 1
    evidence(c, "A2")
  end

  test "A3 crash after intent before launch acknowledgement is held on redelivery", c do
    Fixture.gate(c.fixture, [:admitted])
    worker = deliver(c.turn)
    assert_receive {:barrier, :admitted, _, attempt}
    kill(worker.pid)
    Journal.pause(c.project.id, true)
    Fixture.gate(c.fixture, [])
    assert Task.await(deliver(c.turn)).success == 1
    assert Journal.attempt_for(c.turn.id).id == attempt.id
    assert Journal.turn(c.turn.id).state == "uncertain"
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert Journal.project(c.project.id).paused
    assert Journal.attempt(attempt.id).phase == "admitted"
    assert launches(c) == 0
    evidence(c, "A3")
  end

  test "A3b death after durable consumption before native launch cannot be replayed", c do
    Fixture.gate(c.fixture, [:before_native_launch])
    worker = deliver(c.turn)
    assert_receive {:barrier, :before_native_launch, _, _}
    attempt = Journal.attempt_for(c.turn.id)
    assert attempt.phase == "dispatching"
    kill(worker.pid)
    kill(GenAgent.whereis(c.lead))
    Journal.pause(c.project.id, true)
    assert Task.await(redeliver(c.turn)).success == 1
    assert Journal.turn(c.turn.id).state == "uncertain"
    assert is_nil(Journal.attempt(attempt.id).native)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert launches(c) == 0
    Journal.pause(c.project.id, false)
    assert Journal.admit(c.successor.id) == {:ok, :held}
    evidence(c, "A3b")
  end

  test "A4 duplicates, stale permits and callback followups cannot bypass pause or generation",
       c do
    Journal.pause(c.project.id, true)
    assert Task.await(deliver(c.turn)).snoozed == 1
    assert Task.await(deliver(c.turn)).snoozed == 1
    assert launches(c) == 0
    Journal.pause(c.project.id, false)
    Fixture.gate(c.fixture, [:admitted])
    worker = deliver(c.turn)
    assert_receive {:barrier, :admitted, pid, attempt}
    stale = %{attempt | generation: attempt.generation + 1} |> Journal.prompt()
    refute Journal.consume(stale, c.project.id)
    Journal.pause(c.project.id, true)
    send(pid, {:release, :admitted})
    started()
    Fixture.gate(c.fixture, [])
    assert Task.await(deliver(c.turn)).success == 1
    finish(c, attempt)
    assert Task.await(worker).success == 1
    GenAgent.notify_ack(c.lead, {:unadmitted_followup, Journal.prompt(attempt)})
    assert {:error, :pre_turn_skipped} = GenAgent.ask(c.lead, Journal.prompt(attempt))
    assert Journal.project(c.project.id).paused
    assert launches(c) == 1
    evidence(c, "A4")
  end

  test "B1 killing the Oban executor does not kill the provider or independent receipt", c do
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    await(fn -> Journal.attempt(attempt.id).native != nil end, 1_000)
    kill(worker.pid)
    effect(c, "cli")
    finish(c, attempt)
    assert Task.await(redeliver(c.turn)).success == 1
    assert launches(c) == 1
    assert_report(c, attempt)
    evidence(c, "B1")
  end

  test "B2 receipt blocked before commit survives waiter death", c do
    Fixture.gate(c.fixture, [:before_receipt])
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    Fixture.command(c.fixture, "cli", "result")
    assert_receive {:barrier, :before_receipt, sink, _}
    assert is_nil(Journal.attempt(attempt.id).terminal)
    kill(worker.pid)
    send(sink, {:release, :before_receipt})
    assert_receive {:barrier, :receipt, _, _}
    exit_fixture(c, attempt)
    assert {:settled, _} = Runtime.reconcile(attempt, c.fixture)
    assert_report(c, attempt)
    assert launches(c) == 1
    evidence(c, "B2")
  end

  test "B3 settlement survives death before Oban acknowledgement and duplicate terminal", c do
    Fixture.gate(c.fixture, [:before_ack])
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    finish(c, attempt)
    assert_receive {:barrier, :before_ack, _, _}
    original = Journal.turn(c.turn.id).report
    kill(worker.pid)
    assert Task.await(redeliver(c.turn)).success == 1
    Journal.terminal(attempt.id, %{"text" => "late conflicting duplicate"})
    assert Journal.turn(c.turn.id).report == original
    assert_report(c, attempt)
    assert launches(c) == 1
    {:ok, {:new, successor_attempt}} = Journal.admit(c.successor.id)
    Journal.terminal(attempt.id, %{"text" => "another late duplicate"})

    assert {:error, :unbound_evidence} =
             Journal.quiescent(successor_attempt.id, Journal.attempt(attempt.id).quiescence)

    assert Journal.project(c.project.id).active_turn_id == c.successor.id
    evidence(c, "B3")
  end

  test "B4 lost volatile outcome remains uncertain even after native exit", c do
    Fixture.gate(c.fixture, [:before_receipt])
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    Fixture.command(c.fixture, "cli", "result")
    assert_receive {:barrier, :before_receipt, sink, _}
    kill(sink)
    kill(worker.pid)
    GenAgent.stop(c.lead)
    exit_fixture(c, attempt)
    stop_supervised(Repo)
    start_supervised!({Repo, c.repo_opts})
    assert Task.await(deliver(c.turn)).success == 1
    assert is_nil(Journal.attempt(attempt.id).terminal)
    assert is_nil(Journal.turn(c.turn.id).report)
    assert Journal.turn(c.turn.id).state == "uncertain"
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert launches(c) == 1
    evidence(c, "B4")
  end

  test "C1 terminal result with a live tool cannot release the slot", c do
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    Fixture.command(c.fixture, "cli", "result")
    assert_receive {:barrier, :receipt, _, _}
    effect(c, "tool")
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    assert is_nil(Journal.turn(c.turn.id).report)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    exit_fixture(c, attempt)
    assert {:settled, _} = Runtime.reconcile(attempt, c.fixture)
    assert Task.await(worker).success == 1
    evidence(c, "C1")
  end

  test "C2 a stop acknowledgement while effects continue is not quiescence", c do
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    Journal.request_stop(attempt.id)
    Fixture.command(c.fixture, "cli", "ack_stop")
    assert_receive {:native, %{"event" => "stop_acknowledged"}}
    effect(c, "tool")
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    assert is_nil(Journal.attempt(attempt.id).quiescence)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    kill(worker.pid)
    exit_fixture(c, attempt)
    evidence(c, "C2")
  end

  test "C3 interruption escalates after ignored TERM; native exit does not invent an outcome",
       c do
    worker = deliver(c.turn)
    started()
    assert_receive {:barrier, :handed_off, _, ref}
    attempt = Journal.attempt_for(c.turn.id)
    Journal.request_stop(attempt.id)
    assert {:ok, :accepted} = GenAgent.interrupt_request(c.lead, ref)
    assert_receive {:native, %{"event" => "term_ignored"}}
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    await(fn -> Fixture.quiescence(c.fixture, attempt.id) != :unknown end, 8_000)
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    assert Journal.attempt(attempt.id).quiescence
    assert is_nil(Journal.turn(c.turn.id).report)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    kill(worker.pid)
    evidence(c, "C3")
  end

  @tag escape: true
  test "C4 abrupt lead death cannot hide an escaped descendant", c do
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    kill(GenAgent.whereis(c.lead))
    assert_receive {:native, %{"event" => "term_ignored", "role" => "cli"}}
    await(fn -> Fixture.status(c.fixture, "cli") in ["absent", "zombie"] end, 8_000)
    assert Fixture.status(c.fixture, "tool") == "alive"
    hellos = Enum.filter(Fixture.trace(c.fixture), &(&1["event"] == "hello"))
    assert length(Enum.uniq_by(hellos, & &1["pgid"])) == 2
    effect(c, "tool")
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    assert is_nil(Journal.attempt(attempt.id).quiescence)
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert Task.await(deliver(c.turn)).success == 1
    assert launches(c) == 1
    kill(worker.pid)
    exit_fixture(c, attempt)
    evidence(c, "C4")
  end

  test "C4b abrupt lead death stops the closed process group and preserves uncertainty", c do
    worker = deliver(c.turn)
    started()
    attempt = Journal.attempt_for(c.turn.id)
    kill(GenAgent.whereis(c.lead))
    assert_receive {:native, %{"event" => "term_ignored"}}
    await(fn -> Fixture.quiescence(c.fixture, attempt.id) != :unknown end, 8_000)
    assert Runtime.reconcile(attempt, c.fixture) == :uncertain
    assert Journal.attempt(attempt.id).quiescence
    assert Journal.project(c.project.id).active_turn_id == c.turn.id
    assert is_nil(Journal.turn(c.turn.id).report)
    kill(worker.pid)
    evidence(c, "C4b")
  end

  defp deliver(turn) do
    {:ok, _job} = Oban.insert(ProofOban, Worker.new(%{"turn" => turn.id}))
    drain()
  end

  # Simulate a recovery service redelivering the exact durable job only after
  # its executor's DOWN has been observed. Oban's real fetch/execute/ack path runs.
  defp redeliver(turn) do
    job =
      Repo.all(from(j in Oban.Job, where: j.state == "executing"))
      |> Enum.find(&(&1.args["turn"] == turn.id))

    assert job
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "available"])
    drain()
  end

  defp drain do
    Task.Supervisor.async_nolink(ProofTasks, fn ->
      Oban.drain_queue(ProofOban, queue: :proof, with_limit: 1)
    end)
  end

  defp started do
    assert_receive {:native, %{"event" => "hello", "role" => "cli"}}
    assert_receive {:native, %{"event" => "hello", "role" => "tool"}}
  end

  defp finish(c, attempt) do
    Fixture.command(c.fixture, "cli", "result")
    assert_receive {:barrier, :receipt, _, _}
    exit_fixture(c, attempt)
    assert {:settled, _} = Runtime.reconcile(attempt, c.fixture)
    assert_report(c, attempt)
  end

  defp exit_fixture(c, attempt) do
    Fixture.command(c.fixture, "tool", "exit")
    Fixture.command(c.fixture, "cli", "exit")
    await(fn -> Fixture.quiescence(c.fixture, attempt.id) != :unknown end, 8_000)
  end

  defp effect(c, role) do
    Fixture.command(c.fixture, role, "effect")
    assert_receive {:native, %{"event" => "effect_written", "role" => ^role}}
    assert File.read!(Path.join(c.directory, role <> ".effects")) =~ "effect"
  end

  defp assert_report(c, attempt) do
    assert Journal.turn(c.turn.id).report == %{
             "text" => "fixture answer",
             "attempt_id" => attempt.id
           }

    assert Repo.aggregate(from(t in Turn, where: not is_nil(t.report)), :count) == 1
    assert is_nil(Journal.project(c.project.id).active_turn_id)
    assert Journal.attempt(attempt.id).native == %{"session_id" => "fixture-#{attempt.id}"}
    assert map_size(Journal.attempt(attempt.id).native_inventory) == 2
  end

  defp launches(c) do
    Enum.count(Fixture.trace(c.fixture), &(&1["event"] == "hello" and &1["role"] == "cli"))
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp await(predicate, remaining) do
    if predicate.() do
      :ok
    else
      assert remaining > 0, "native observation did not reach expected state"

      receive do
      after
        10 -> :ok
      end

      await(predicate, remaining - 10)
    end
  end

  defp evidence(c, scenario) do
    File.mkdir_p!("tmp/evidence")

    snapshot = fn schema ->
      Repo.all(schema) |> Enum.map(&(Map.from_struct(&1) |> Map.drop([:__meta__])))
    end

    evidence = %{
      scenario: scenario,
      seed: ExUnit.configuration()[:seed],
      projects: snapshot.(Project),
      turns: snapshot.(Turn),
      attempts: snapshot.(Attempt),
      jobs: Repo.all(from(j in Oban.Job, select: map(j, [:id, :args, :state, :attempt]))),
      trace: Fixture.trace(c.fixture)
    }

    File.write!(
      "tmp/evidence/#{scenario}-#{ExUnit.configuration()[:seed]}.json",
      Jason.encode!(evidence, pretty: true)
    )
  end
end
