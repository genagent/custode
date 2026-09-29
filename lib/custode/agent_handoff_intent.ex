defmodule Custode.AgentHandoffIntent do
  @moduledoc """
  Durable safety intent carried across a live-agent configuration handoff.

  The coordinator records a non-configuration pause before stopping the old
  provider process. It clears the row only after the replacement is confirmed
  paused, so a crash in the stop/start window cannot silently resume work.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @primary_key {:agent_id, :string, autogenerate: false}
  schema "agent_handoff_intents" do
    field(:pause_context, :map)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def get(agent_id) when is_binary(agent_id) do
    case Repo.get(__MODULE__, agent_id) do
      nil -> nil
      %__MODULE__{pause_context: context} -> context
    end
  end

  @doc false
  def put(agent_id, pause_context) when is_binary(agent_id) and is_map(pause_context) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> changeset(%{
      agent_id: agent_id,
      pause_context: stringify_keys(pause_context),
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert(
      on_conflict: [set: [pause_context: stringify_keys(pause_context), updated_at: now]],
      conflict_target: :agent_id
    )
    |> case do
      {:ok, _intent} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc false
  def clear(agent_id) when is_binary(agent_id) do
    Repo.delete_all(from(intent in __MODULE__, where: intent.agent_id == ^agent_id))
    :ok
  end

  @doc false
  def clear_absent(agent_ids) when is_list(agent_ids) do
    query =
      case agent_ids do
        [] -> from(intent in __MODULE__, where: true)
        ids -> from(intent in __MODULE__, where: intent.agent_id not in ^ids)
      end

    Repo.delete_all(query)
    :ok
  end

  defp changeset(intent, attrs) do
    intent
    |> cast(attrs, [:agent_id, :pause_context, :inserted_at, :updated_at])
    |> validate_required([:agent_id, :pause_context, :inserted_at, :updated_at])
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
