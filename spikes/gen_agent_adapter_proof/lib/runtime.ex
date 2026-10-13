defmodule AdapterProof.Barrier do
  @moduledoc false

  def hit(fixture, event, payload \\ nil) do
    {observer, gated} = GenServer.call(fixture, {:barrier, event})
    send(observer, {:barrier, event, self(), payload})

    if gated do
      receive do
        {:release, ^event} -> :ok
      after
        15_000 -> raise "unreleased proof barrier #{event}"
      end
    end

    :ok
  end
end

defmodule AdapterProof.GuardedRunner do
  @moduledoc "Reject every executable except the checked-in synthetic CLI."
  @behaviour ClaudeWrapper.Runner
  alias ClaudeWrapper.Runner.Forcola, as: NativeRunner

  @impl true
  def run(_, _, _, _), do: raise("proof permits streaming only")

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    if binary != Path.expand("test/fixtures/cli.py"), do: raise("live executable forbidden")
    %{"spec" => %{"provider" => provider}} = args |> List.last() |> Jason.decode!()
    digest = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16()
    if digest != provider["binary_sha256"], do: raise("fixture executable changed since capture")
    NativeRunner.stream_lines(binary, args, opts, timeout)
  end
end

defmodule AdapterProof.Backend do
  @moduledoc false
  @behaviour GenAgent.Backend
  alias AdapterProof.{Barrier, Journal}
  alias GenAgent.Backends.Claude

  @impl true
  def start_session(opts) do
    spec = Keyword.fetch!(opts, :launch_spec)
    provider = spec["provider"]
    if provider["permission_mode"] != "dont_ask", do: raise("unsupported proof permission mode")

    backend_opts = [
      binary: provider["binary"],
      working_dir: provider["working_dir"],
      timeout: provider["timeout"],
      model: provider["model"],
      tools: provider["tools"],
      max_turns: provider["max_turns"],
      permission_mode: :dont_ask
    ]

    with {:ok, inner} <- Claude.start_session(backend_opts) do
      {:ok, %{inner: inner, sink: opts[:sink], fixture: opts[:fixture], spec: spec}}
    end
  end

  @impl true
  def prompt(session, prompt), do: prompt(session, prompt, %{checkpoint: fn _ -> :ok end})

  @impl true
  def prompt(session, prompt, context) do
    %{"attempt" => id, "spec" => spec} = Jason.decode!(prompt)
    if spec != session.spec, do: raise("runtime does not match captured launch spec")
    Barrier.hit(session.fixture, :before_native_launch, id)

    checkpoint = fn native ->
      Journal.checkpoint(id, native)
      context.checkpoint.(native)
    end

    with {:ok, stream, inner} <- Claude.prompt(session.inner, prompt, %{checkpoint: checkpoint}) do
      stream = Stream.each(stream, &observe(&1, session.sink, id))

      {:ok, stream, %{session | inner: inner}}
    end
  end

  defp observe(%{kind: :result, data: data}, sink, id),
    do: GenServer.cast(sink, {:terminal, id, %{"text" => data.text}})

  defp observe(_, _, _), do: :ok

  @impl true
  def checkpoint_session(session, id),
    do: %{session | inner: Claude.checkpoint_session(session.inner, id)}

  @impl true
  def update_session(session, data),
    do: %{session | inner: Claude.update_session(session.inner, data)}

  @impl true
  def terminate_session(session), do: Claude.terminate_session(session.inner)
end

defmodule AdapterProof.Lead do
  @moduledoc false
  use GenAgent
  alias AdapterProof.Journal

  @impl true
  def init_agent(opts),
    do: {:ok, Keyword.fetch!(opts, :backend_opts), %{project: Keyword.fetch!(opts, :project)}}

  @impl true
  def pre_turn(prompt, state) do
    if Journal.consume(prompt, state.project), do: {:ok, prompt, state}, else: {:skip, state}
  end

  @impl true
  def handle_response(_, _, state), do: {:noreply, state}

  # A deliberately hostile callback-generated prompt must still hit pre_turn.
  @impl true
  def handle_event({:unadmitted_followup, prompt}, state), do: {:prompt, prompt, state}
end

defmodule AdapterProof.Sink do
  @moduledoc "Independent result ingestion; never a child of the Oban waiter."
  use GenServer
  alias AdapterProof.{Barrier, Journal}
  def start_link(fixture), do: GenServer.start_link(__MODULE__, fixture)
  @impl true
  def init(fixture), do: {:ok, fixture}
  @impl true
  def handle_cast({:terminal, id, value}, fixture) do
    Barrier.hit(fixture, :before_receipt, id)
    Journal.terminal(id, value)
    Barrier.hit(fixture, :receipt, id)
    {:noreply, fixture}
  end

  @impl true
  def handle_info({:gen_agent, :completion, _, _, _}, fixture), do: {:noreply, fixture}
end

defmodule AdapterProof.Runtime do
  @moduledoc false
  alias AdapterProof.{Fixture, Journal}

  def bind(project, lead, sink, fixture),
    do: :ets.insert(__MODULE__, {project, lead, sink, fixture})

  def lookup(project) do
    [{^project, lead, sink, fixture}] = :ets.lookup(__MODULE__, project)
    {lead, sink, fixture}
  end

  def reconcile(attempt, fixture) do
    case Fixture.quiescence(fixture, attempt.id) do
      {:ok, evidence} -> Journal.quiescent(attempt.id, evidence)
      :unknown -> :unknown
    end

    turn = Journal.turn(attempt.turn_id)

    if turn.report do
      GenServer.call(fixture, {:settled, turn.id})
      {:settled, turn}
    else
      Journal.uncertain(attempt.id)
      :uncertain
    end
  end
end

defmodule AdapterProof.Worker do
  @moduledoc false
  use Oban.Worker, queue: :proof, max_attempts: 3
  alias AdapterProof.{Barrier, Journal, Runtime}

  @impl true
  def perform(%Oban.Job{args: %{"turn" => id}}) do
    turn = Journal.turn(id)
    {lead, sink, fixture} = Runtime.lookup(turn.project_id)
    Barrier.hit(fixture, :before_admission, id)

    case Journal.admit(id) do
      {:ok, :held} ->
        {:snooze, 60}

      {:ok, {:existing, attempt}} ->
        Runtime.reconcile(attempt, fixture)
        :ok

      {:ok, {:new, attempt}} ->
        GenServer.call(fixture, {:waiter, id, self()})
        Barrier.hit(fixture, :admitted, attempt)
        {:ok, ref} = GenAgent.tell_with_completion(lead, Journal.prompt(attempt), sink)
        Barrier.hit(fixture, :handed_off, ref)

        receive do
          {:settled, ^id} -> Barrier.hit(fixture, :before_ack, id)
        after
          20_000 -> raise "fixture did not settle"
        end

        :ok
    end
  end
end
