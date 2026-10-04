defmodule Custode.SubjectDocumentBridge do
  @moduledoc "Owns optional POSIX directory-descriptor ports, independently of agent workspaces."
  use GenServer
  alias Custode.Repo

  defmodule Binding do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:root_id, :string, autogenerate: false}
    schema "subject_root_bindings" do
      field(:binding, :map)
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def invoke(definition, request),
    do: GenServer.call(__MODULE__, {:invoke, definition, request}, 15_000)

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:invoke, definition, request}, _from, state) do
    if definition in Application.get_env(:custode, :subject_roots, []) do
      {reply, updated} = invoke_root(definition, request, state)
      {:reply, reply, updated}
    else
      {:reply, {:error, "root_configuration_changed"}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state, fn {_id, info} -> close(info.port) end)
    {:reply, :ok, %{}}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, _status}}, state),
    do: {:noreply, forget_port(state, port)}

  def handle_info({port, :closed}, state), do: {:noreply, forget_port(state, port)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: Enum.each(state, fn {_id, info} -> close(info.port) end)

  defp invoke_root(definition, request, state) do
    revision = Custode.SubjectDocuments.digest(definition)

    case state[definition.id] do
      %{revision: ^revision} = info ->
        execute(info, request, state, definition.id)

      old ->
        if old, do: close(old.port)
        open_and_execute(definition, revision, request, Map.delete(state, definition.id))
    end
  end

  defp open_and_execute(definition, revision, request, state) do
    with {:ok, port} <- open_port(),
         {:ok, info} <- bind_root(port, definition, revision) do
      execute(info, request, Map.put(state, definition.id, info), definition.id)
    else
      error -> {error, state}
    end
  end

  defp bind_root(port, definition, revision) do
    expected =
      case Repo.get(Binding, definition.id) do
        nil -> nil
        row -> row.binding
      end

    case exchange(port, %{
           "action" => "bind",
           "root" => Path.expand(definition.path),
           "expected" => expected
         }) do
      {:ok, %{"binding" => binding}} ->
        Repo.insert!(%Binding{root_id: definition.id, binding: binding}, on_conflict: :nothing)
        {:ok, %{port: port, revision: revision, binding: binding}}

      error ->
        close(port)
        error
    end
  end

  defp execute(info, %{"action" => "binding"}, state, _id), do: {{:ok, info.binding}, state}

  defp execute(info, request, state, id) do
    case exchange(info.port, request) do
      {:ok, result} ->
        {{:ok, Map.put(result, "root_binding", info.binding)}, state}

      {:error, error} = refused when error in ~w(port_timeout port_closed invalid_response) ->
        close(info.port)
        {refused, Map.delete(state, id)}

      refused ->
        {refused, state}
    end
  end

  defp open_port do
    python = Application.get_env(:custode, :subject_python) || System.find_executable("python3")
    helper = Application.app_dir(:custode, "priv/native/subject_documents.py")

    if is_binary(python) and File.regular?(helper) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, ["-I", "-u", helper]},
          {:line, 200_000}
        ])

      {:ok, port}
    else
      {:error, "descriptor_helper_unavailable"}
    end
  rescue
    _error -> {:error, "descriptor_helper_unavailable"}
  end

  defp exchange(port, request) do
    payload = Jason.encode!(request) <> "\n"

    if byte_size(payload) > 200_000 do
      {:error, "frame_limit"}
    else
      Port.command(port, payload)
      receive_response(port)
    end
  rescue
    _error -> {:error, "port_closed"}
  end

  defp receive_response(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> decode(line)
      {^port, {:data, {:noeol, _part}}} -> {:error, "invalid_response"}
      {^port, {:exit_status, _status}} -> {:error, "port_closed"}
    after
      5_000 -> {:error, "port_timeout"}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{"ok" => true, "result" => result}} when is_map(result) -> {:ok, result}
      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) -> {:error, error}
      _invalid -> {:error, "invalid_response"}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  end

  defp forget_port(state, port), do: Map.reject(state, fn {_id, info} -> info.port == port end)
end
