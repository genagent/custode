defmodule Custode.MCP.MemoryTools.Remember do
  @moduledoc "Persist a fact for yourself across sessions (upserts by key)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @key "short kebab-case slug"
  @value "the fact to keep, as text"

  # Both identity names are optional (#483): the token says who is calling,
  # and the notebook tools call the same id `routine_id`.
  schema do
    field(:agent_id, :string, description: "your own agent/routine id (defaults to the caller)")
    field(:routine_id, :string, description: alias_for("agent_id"))
    field(:key, :string, description: @key)
    field(:value, :string, description: @value)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, agent_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, agent_id),
         {:ok, key} <- need(params, :key, @key),
         {:ok, value} <- need(params, :value, @value) do
      put(agent_id, key, value, frame)
    else
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
    field(:agent_id, :string, description: "your own agent/routine id (defaults to the caller)")
    field(:routine_id, :string, description: alias_for("agent_id"))
    field(:key, :string, description: "omit to recall everything")
  end

  # A read, so no check_self/2: reads are not scoped, and the id only
  # defaults to the caller (#483).
  @impl true
  def execute(params, frame) do
    case fetch_self(params, frame) do
      {:ok, agent_id} -> recall(agent_id, params[:key], frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp recall(agent_id, nil, frame) do
    memories = for m <- Custode.Memory.recall(agent_id), do: %{key: m.key, value: m.value}
    reply(frame, %{memories: memories})
  end

  defp recall(agent_id, key, frame) do
    case Custode.Memory.recall(agent_id, key) do
      {:ok, value} -> reply(frame, %{key: key, value: value})
      :error -> fail(frame, "nothing remembered under #{inspect(key)}")
    end
  end
end

defmodule Custode.MCP.MemoryTools.Forget do
  @moduledoc "Delete one of your memories by key."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @key "the key of the memory to delete (see: recall)"

  schema do
    field(:agent_id, :string, description: "your own agent/routine id (defaults to the caller)")
    field(:routine_id, :string, description: alias_for("agent_id"))
    field(:key, :string, description: @key)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, agent_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, agent_id),
         {:ok, key} <- need(params, :key, @key) do
      drop(agent_id, key, frame)
    else
      {:error, message} -> fail(frame, message)
    end
  end

  defp drop(agent_id, key, frame) do
    :ok = Custode.Memory.forget(agent_id, key)
    reply(frame, %{forgot: key})
  end
end
