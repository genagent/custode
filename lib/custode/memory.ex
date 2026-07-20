defmodule Custode.Memory do
  @moduledoc """
  Per-agent persistent key-value memory. Every turn is a fresh claude session,
  so anything an agent wants to carry across sweeps goes here via its
  `remember` / `recall` / `forget` MCP tools -- the agent wakes up knowing the
  tools exist (their schemas ride into every session via `mcp_config`) and its
  standing orders say to recall first.

  Scoped by `agent_id`, so sub-agents get memory too (through the
  memory-only MCP server, which exposes nothing else).
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    schema "memories" do
      field(:agent_id, :string)
      field(:key, :string)
      field(:value, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc "Upsert one memory."
  def remember(agent_id, key, value)
      when is_binary(agent_id) and is_binary(key) and is_binary(value) do
    Repo.insert!(
      %Entry{agent_id: agent_id, key: key, value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:agent_id, :key]
    )

    :ok
  end

  @doc "All of an agent's memories, sorted by key."
  def recall(agent_id) do
    Repo.all(from(m in Entry, where: m.agent_id == ^agent_id, order_by: [asc: m.key]))
  end

  @doc "One memory by key."
  def recall(agent_id, key) do
    case Repo.get_by(Entry, agent_id: agent_id, key: key) do
      nil -> :error
      entry -> {:ok, entry.value}
    end
  end

  @doc "Delete one memory by key (idempotent)."
  def forget(agent_id, key) do
    Repo.delete_all(from(m in Entry, where: m.agent_id == ^agent_id and m.key == ^key))
    :ok
  end
end
