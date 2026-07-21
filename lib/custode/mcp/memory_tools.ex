defmodule Custode.MCP.MemoryTools.Remember do
  @moduledoc "Persist a fact for yourself across sessions (upserts by key)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "your own agent/routine id")
    field(:key, :string, required: true, description: "short kebab-case slug")
    field(:value, :string, required: true)
  end

  @impl true
  def execute(%{agent_id: agent_id, key: key, value: value}, frame) do
    case check_self(frame, agent_id) do
      :ok -> put(agent_id, key, value, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp put(agent_id, key, value, frame) do
    :ok = Custode.Memory.remember(agent_id, key, value)
    reply(frame, %{remembered: key})
  end
end

defmodule Custode.MCP.MemoryTools.Recall do
  @moduledoc "Recall your persistent memory: one key, or everything you know."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "your own agent/routine id")
    field(:key, :string, description: "omit to recall everything")
  end

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    case params[:key] do
      nil ->
        memories = for m <- Custode.Memory.recall(agent_id), do: %{key: m.key, value: m.value}
        reply(frame, %{memories: memories})

      key ->
        case Custode.Memory.recall(agent_id, key) do
          {:ok, value} -> reply(frame, %{key: key, value: value})
          :error -> fail(frame, "nothing remembered under #{inspect(key)}")
        end
    end
  end
end

defmodule Custode.MCP.MemoryTools.Forget do
  @moduledoc "Delete one of your memories by key."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "your own agent/routine id")
    field(:key, :string, required: true)
  end

  @impl true
  def execute(%{agent_id: agent_id, key: key}, frame) do
    case check_self(frame, agent_id) do
      :ok -> drop(agent_id, key, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp drop(agent_id, key, frame) do
    :ok = Custode.Memory.forget(agent_id, key)
    reply(frame, %{forgot: key})
  end
end
