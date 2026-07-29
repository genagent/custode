defmodule Custode.Missions do
  @moduledoc "Mission lifecycle, typed targets, archive eligibility, and bootstrap declarations."

  import Ecto.Query, only: [from: 2]

  alias Custode.{Mission, MissionTarget, OperationCall, Repo, WorkItem}
  alias Custode.Operations.Missions.Create

  @active_call_statuses ~w(proposed waiting running)
  @nonterminal_work_states ~w(proposed ready active waiting blocked)

  def list do
    Mission
    |> Repo.all()
    |> Repo.preload(:targets)
  end

  def get(mission_id), do: Mission |> Repo.get_by(mission_id: mission_id) |> preload()
  def get_by_key(key), do: Mission |> Repo.get_by(key: key) |> preload()

  def create(attrs) do
    Repo.transaction(fn ->
      attrs = Map.new(attrs)
      changeset = Mission.create_changeset(Map.put(attrs, :mission_id, Ecto.UUID.generate()))

      changeset
      |> Repo.insert()
      |> handle_create_result(attrs)
    end)
    |> unwrap()
  end

  def update(mission_id, attrs) do
    Repo.transaction(fn ->
      mission = get!(mission_id)

      if mission.status == "archived", do: Repo.rollback(:mission_archived)

      attrs = Map.new(attrs)

      mission =
        mission
        |> Mission.update_changeset(Map.drop(attrs, [:target]))
        |> update_or_rollback()

      mission
      |> maybe_upsert_target!(attrs[:target])
      |> Repo.preload(:targets, force: true)
    end)
    |> unwrap()
  end

  def archive(mission_id, current_call_id) do
    Repo.transaction(fn ->
      mission = get!(mission_id)

      cond do
        mission.status == "archived" ->
          mission

        obligation = active_work_item(mission) ->
          Repo.rollback({:active_obligation, obligation})

        obligation = active_operation_call(mission_id, current_call_id) ->
          Repo.rollback({:active_obligation, obligation})

        not retention_elapsed?(mission) ->
          Repo.rollback({:active_obligation, retention_obligation(mission)})

        true ->
          mission
          |> Mission.update_changeset(%{status: "archived", archived_at: DateTime.utc_now()})
          |> Repo.update!()
          |> Repo.preload(:targets)
      end
    end)
    |> unwrap()
  end

  def render(%Mission{} = mission) do
    mission = preload(mission)

    %{
      mission_id: mission.mission_id,
      key: mission.key,
      purpose: mission.purpose,
      lifecycle: mission.lifecycle,
      status: mission.status,
      policy_ref: mission.policy_ref,
      budget_ref: mission.budget_ref,
      context_ref: mission.context_ref,
      retention_seconds: mission.retention_seconds,
      metadata: mission.metadata,
      archived_at: mission.archived_at && DateTime.to_iso8601(mission.archived_at),
      targets: Enum.map(mission.targets, &render_target/1)
    }
  end

  def bootstrap! do
    Enum.each(Application.get_env(:custode, :missions, []), fn declaration ->
      attrs = Map.new(declaration)
      key = Map.fetch!(attrs, :key)

      {:ok, _response} =
        Create.dispatch(attrs,
          actor: %{kind: :system, id: "bootstrap"},
          transport: :system,
          idempotency_key: "bootstrap:mission:#{key}:v1"
        )
    end)

    :ok
  end

  defp get!(mission_id) do
    case get(mission_id) do
      nil -> Repo.rollback({:unknown_mission, mission_id})
      mission -> mission
    end
  end

  defp handle_create_result({:ok, mission}, attrs) do
    {:created, insert_targets!(mission, Map.fetch!(attrs, :targets))}
  end

  defp handle_create_result({:error, changeset}, attrs) do
    if unique_key?(changeset) do
      {:existing, get_by_key(Map.fetch!(attrs, :key))}
    else
      Repo.rollback(changeset)
    end
  end

  defp insert_targets!(mission, targets) when is_list(targets) and targets != [] do
    Enum.each(targets, fn target ->
      target
      |> Map.new()
      |> Map.put(:mission_id, mission.id)
      |> then(&MissionTarget.changeset(%MissionTarget{}, &1))
      |> insert_or_rollback()
    end)

    Repo.preload(mission, :targets)
  end

  defp insert_targets!(_mission, _targets), do: Repo.rollback(:targets_required)
  defp maybe_upsert_target!(mission, nil), do: mission

  defp maybe_upsert_target!(mission, target) do
    attrs = target |> Map.new() |> Map.put(:mission_id, mission.id)

    existing =
      Repo.get_by(MissionTarget,
        mission_id: mission.id,
        kind: attrs[:kind] || attrs["kind"],
        external_id: attrs[:external_id] || attrs["external_id"]
      )

    (existing || %MissionTarget{})
    |> MissionTarget.changeset(attrs)
    |> insert_or_update_or_rollback()

    mission
  end

  defp active_operation_call(mission_id, current_call_id) do
    from(c in OperationCall,
      where:
        c.mission_id == ^mission_id and c.status in ^@active_call_statuses and
          c.call_id != ^current_call_id,
      order_by: [asc: c.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      call -> %{kind: "operation_call", id: call.call_id, status: call.status}
    end
  end

  defp active_work_item(mission) do
    from(work_item in WorkItem,
      where:
        work_item.mission_id == ^mission.id and
          work_item.state in ^@nonterminal_work_states,
      order_by: [asc: work_item.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      work_item ->
        %{kind: "work_item", id: work_item.work_item_id, status: work_item.state}
    end
  end

  defp retention_elapsed?(%Mission{lifecycle: "persistent"}), do: true

  defp retention_elapsed?(mission) do
    DateTime.compare(DateTime.utc_now(), retention_at(mission)) != :lt
  end

  defp retention_obligation(mission) do
    %{
      kind: "retention",
      id: mission.mission_id,
      eligible_at: DateTime.to_iso8601(retention_at(mission))
    }
  end

  defp retention_at(mission),
    do: DateTime.add(mission.inserted_at, mission.retention_seconds, :second)

  defp render_target(target) do
    %{
      kind: target.kind,
      external_id: target.external_id,
      display_name: target.display_name,
      metadata: target.metadata
    }
  end

  defp preload(nil), do: nil
  defp preload(mission), do: Repo.preload(mission, :targets)
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_or_update_or_rollback(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unique_key?(changeset) do
    Enum.any?(changeset.errors, fn
      {:key, {_message, options}} -> options[:constraint] == :unique
      _other -> false
    end)
  end
end
