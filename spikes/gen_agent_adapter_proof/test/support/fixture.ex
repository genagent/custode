defmodule AdapterProof.Fixture do
  @moduledoc "Independent socket and OS witness for a closed, synthetic process inventory."
  use GenServer
  alias AdapterProof.Journal

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def spec(pid), do: GenServer.call(pid, :spec)
  def gate(pid, events), do: GenServer.call(pid, {:gates, events})
  def command(pid, role, command), do: GenServer.call(pid, {:command, role, command})
  def quiescence(pid, attempt), do: GenServer.call(pid, {:quiescence, attempt})
  def trace(pid), do: GenServer.call(pid, :trace)
  def status(pid, role), do: GenServer.call(pid, {:status, role})

  @impl true
  def init(opts) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(socket)
    owner = self()
    acceptor = spawn_link(fn -> accept(socket, owner) end)

    spec = %{
      "port" => port,
      "token" => Ecto.UUID.generate(),
      "dir" => opts[:dir],
      "escape" => Keyword.get(opts, :escape, false),
      "provider" => %{
        "binary" => Path.expand("test/fixtures/cli.py"),
        "binary_sha256" =>
          Base.encode16(:crypto.hash(:sha256, File.read!("test/fixtures/cli.py"))),
        "working_dir" => opts[:dir],
        "timeout" => 30_000,
        "model" => "fixture",
        "tools" => [""],
        "max_turns" => 1,
        "permission_mode" => "dont_ask",
        "runner" => "ClaudeWrapper.Runner.Forcola"
      }
    }

    {:ok,
     %{
       socket: socket,
       acceptor: acceptor,
       spec: spec,
       observer: opts[:observer],
       gates: [],
       peers: %{},
       waiters: [],
       trace: []
     }}
  end

  @impl true
  def handle_call(:spec, _, state), do: {:reply, state.spec, state}
  def handle_call(:trace, _, state), do: {:reply, Enum.reverse(state.trace), state}

  def handle_call({:status, role}, _, state) do
    %{hello: hello} = Map.fetch!(state.peers, role)
    {:reply, os_state(hello["pid"]), state}
  end

  def handle_call({:gates, gates}, _, state), do: {:reply, :ok, %{state | gates: gates}}

  def handle_call({:barrier, event}, _, state) do
    {:reply, {state.observer, event in state.gates},
     record(state, %{"barrier" => to_string(event), "journal" => Journal.snapshot()})}
  end

  def handle_call({:waiter, id, waiter}, _, state) do
    {:reply, :ok, %{state | waiters: [{id, waiter} | state.waiters]}}
  end

  def handle_call({:settled, id}, _, state) do
    for {^id, waiter} <- state.waiters, do: send(waiter, {:settled, id})
    {:reply, :ok, state}
  end

  def handle_call({:command, role, command}, _, state) do
    %{socket: socket} = Map.fetch!(state.peers, role)
    result = :gen_tcp.send(socket, Jason.encode!(%{command: command}) <> "\n")
    {:reply, result, record(state, %{"command" => command, "role" => role})}
  end

  def handle_call({:quiescence, attempt}, _, state) do
    peers = Map.values(state.peers)

    evidence =
      Enum.map(peers, fn %{hello: hello} ->
        Map.put(hello, "observed_state", os_state(hello["pid"]))
      end)

    stopped =
      length(peers) == 2 and
        Enum.all?(evidence, fn peer ->
          peer["attempt"] == attempt and peer["observed_state"] in ["absent", "zombie"]
        end)

    reply =
      if stopped do
        {:ok,
         %{
           "scope" => "closed_fixture_inventory",
           "token" => state.spec["token"],
           "attempt" => attempt,
           "processes" => evidence
         }}
      else
        :unknown
      end

    {:reply, reply,
     record(state, %{"quiescence" => if(stopped, do: "observed", else: "unknown")})}
  end

  @impl true
  def handle_info({:native, socket, %{"token" => token} = event}, state) do
    if token != state.spec["token"], do: raise("unbound fixture connection")

    state =
      if event["event"] == "hello" do
        {:ok, _} = Journal.observe_native(event["attempt"], event)
        %{state | peers: Map.put(state.peers, event["role"], %{socket: socket, hello: event})}
      else
        state
      end

    send(state.observer, {:native, event})
    {:noreply, record(state, event)}
  end

  @impl true
  def terminate(_, state) do
    for {_, peer} <- state.peers do
      :gen_tcp.send(peer.socket, "{\"command\":\"exit\"}\n")
      :gen_tcp.close(peer.socket)
    end

    :gen_tcp.close(state.socket)
    Process.exit(state.acceptor, :shutdown)
  end

  defp record(%{trace: [%{"quiescence" => value} | _]} = state, %{"quiescence" => value}),
    do: state

  defp record(state, event) do
    event = Map.put(event, "sequence", length(state.trace) + 1)
    %{state | trace: [event | state.trace]}
  end

  defp os_state(pid) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "stat="]) do
      {"", 1} ->
        "absent"

      {status, 0} ->
        if(String.starts_with?(String.trim(status), "Z"), do: "zombie", else: "alive")

      _ ->
        "unknown"
    end
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn -> accept(listener, owner) end)
        read(socket, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read(socket, owner) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        send(owner, {:native, socket, Jason.decode!(line)})
        read(socket, owner)

      {:error, _} ->
        :ok
    end
  end
end
