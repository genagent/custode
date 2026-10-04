defmodule Custode.SubAgents do
  @moduledoc """
  Sub-agent revival (#5): record at spawn; offer, never auto-revive.

  Routines self-heal across restarts because the roster is their spec.
  Sub-agents started via `start_agent` had no spec anywhere -- they died
  with the instance and their work silently evaporated. The `sub_agents`
  row is that spec: parent, workspace, prompt, model, and (kept fresh by a
  telemetry hook) the claude `session_id`, which persists on disk -- so a
  revived sub-agent genuinely remembers its conversation.

  On boot, `reconcile!/0` (a sibling of the gates reconcile) turns every
  surviving row into an ORPHAN NOTICE in the PARENT's inbox: what died,
  when it last worked, and the revival handle -- re-spawn via the ordinary
  `start_agent` tool, then `prompt_agent` with `resume` semantics through
  the recorded session. The parent decides at its next sweep; nothing
  respawns by itself. A process nobody currently wants is not made wanted
  by having existed, and surprise respawns are how fleets get haunted
  (2026-07-21's 13-hour ghost server being the object lesson). Rows are
  deleted after noticing: the notice is the record from then on.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:agent_id, :string, autogenerate: false}
    schema "sub_agents" do
      field(:parent, :string)
      field(:workspace, :string)
      field(:system_prompt, :string)
      field(:model, :string)
      field(:session_id, :string)
      field(:spawned_at, :utc_datetime_usec)
      field(:last_turn_at, :utc_datetime_usec)
    end
  end

  @doc "Record a spawn: the row is the sub-agent's spec (upsert on agent_id)."
  def record_spawn!(agent_id, parent, attrs) do
    Repo.transaction(fn ->
      Custode.HelperRecords.spawn!(agent_id, parent)

      Repo.insert!(
        %Row{
          agent_id: agent_id,
          parent: parent,
          workspace: Map.fetch!(attrs, :workspace),
          system_prompt: Map.get(attrs, :system_prompt),
          model: Map.get(attrs, :model),
          spawned_at: DateTime.utc_now()
        },
        on_conflict: {:replace, [:parent, :workspace, :system_prompt, :model, :spawned_at]},
        conflict_target: :agent_id
      )
    end)

    :ok
  end

  @doc "Remove a sub-agent's row (it ended and nobody needs the spec)."
  def forget(agent_id) do
    {:ok, removed} =
      Repo.transaction(fn ->
        Custode.HelperRecords.remove!(agent_id)
        Repo.delete_all(from(r in Row, where: r.agent_id == ^agent_id))
      end)

    removed
  end

  @doc "The recorded rows, oldest first (test/introspection surface)."
  def all, do: Repo.all(from(r in Row, order_by: r.spawned_at))

  @doc "The durable spawn record for one temporary agent, or nil."
  def get(agent_id), do: Repo.get(Row, agent_id)

  @doc """
  Boot reconciliation: every surviving row is an orphan (sub-agent processes
  never survive a restart). Drop one notice per orphan into its parent's
  inbox with the revival handle, then delete the rows -- the notice is the
  record now. Returns the number of orphans noticed.
  """
  def reconcile! do
    orphans = all()

    Enum.each(orphans, fn row ->
      deliver_notice(row)
      forget(row.agent_id)
    end)

    length(orphans)
  end

  # The parent may itself be gone from the roster (removed from config since
  # the spawn). The notice then goes to the meta-agent -- the fleet's
  # catch-all judgment -- and failing even that, the feed carries the fact.
  # A row is always cleared: an undeliverable orphan must not re-nag forever.
  defp deliver_notice(row) do
    name = "orphan-#{row.agent_id}-#{System.unique_integer([:positive])}.md"

    case Custode.Inbox.drop(row.parent, name, notice(row)) do
      {:ok, _path} ->
        :ok

      {:error, _reason} ->
        case Custode.Inbox.drop("custode", name, notice(row)) do
          {:ok, _path} ->
            :ok

          {:error, _reason} ->
            Custode.Feed.record(%{
              event: "turn_failed",
              agent: row.parent,
              kind: "orphan_notice_undeliverable",
              detail: "sub-agent #{row.agent_id} orphaned; no inbox for #{row.parent} or custode"
            })
        end
    end
  end

  @doc false
  # Keep session_id and last_turn_at fresh from the run telemetry: the job
  # meta carries the agent id, the result carries the session. Armored --
  # a raising telemetry handler gets detached (audit 2026-07-21).
  def handle_event([:oban_claude, :run, :stop], _measurements, meta, _config) do
    with %{job: %{meta: %{"agent_id" => agent_id}}} <- meta,
         session_id when is_binary(session_id) <- meta.result.session_id do
      Repo.update_all(
        from(r in Row, where: r.agent_id == ^agent_id),
        set: [session_id: session_id, last_turn_at: DateTime.utc_now()]
      )
    end

    :ok
  rescue
    exception ->
      require Logger

      Logger.error(
        "Custode.SubAgents handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def attach do
    :telemetry.attach(
      "custode-sub-agents",
      [:oban_claude, :run, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  defp notice(row) do
    """
    # Orphaned sub-agent: #{row.agent_id}

    Your sub-agent `#{row.agent_id}` did not survive the last restart.
    Spawned #{DateTime.to_iso8601(row.spawned_at)}#{last_worked(row)}.

    ## Revival handle (your judgment -- nothing revives automatically)

    - workspace: `#{row.workspace}`
    - model: #{row.model || "(default)"}
    - resume session: #{row.session_id || "(no completed turn -- fresh start only)"}

    To revive: `start_agent` with the same agent_id and workspace, then
    prompt it#{resume_hint(row)}. To let it go: journal what it was doing
    and why it is done, so the record survives you.
    """
  end

  defp last_worked(%{last_turn_at: nil}), do: ", never completed a turn"

  defp last_worked(%{last_turn_at: at}), do: ", last worked #{DateTime.to_iso8601(at)}"

  defp resume_hint(%{session_id: nil}), do: ""

  defp resume_hint(%{session_id: session_id}),
    do: " (its claude session `#{session_id}` persists on disk and can be resumed)"
end
