defmodule Custode.Gates do
  @moduledoc """
  Durable record of the gated states. The machine's pending approval/question
  lives in the gen_statem and dies with it; this table records every gate as
  it opens (from transition telemetry) and resolves it when the agent leaves
  the gated state.

  On boot, `reconcile!/0` turns each still-open gate belonging to a
  configured routine into a RESTART NOTICE inbox note -- the next sweep reads
  it and re-raises the gate if still warranted. No fake state is injected
  into the machine; the agent re-derives its own gate, custode-style. Open
  gates of non-routine agents (sub-agents, which do not revive) are marked
  orphaned.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Gate do
    @moduledoc false
    use Ecto.Schema

    schema "gates" do
      field(:agent_id, :string)
      field(:kind, :string)
      field(:action_id, :string)
      field(:detail, :string)
      field(:status, :string, default: "open")
      timestamps(type: :utc_datetime_usec)
    end
  end

  @gated [:awaiting_permission, :waiting_for_user]

  def attach do
    :telemetry.attach(
      "custode-gates",
      [:oban_claude, :agent, :transition],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  # Opens run after resolves so an approval that chains straight into a new
  # gate (possible via directives) never resolves its own fresh row.
  def handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    if meta.from in @gated, do: resolve_open(meta.agent_id)
    if meta.to in @gated, do: open(meta.agent_id, meta.to)
    :ok
  end

  @doc "Open gates for an agent."
  def open_gates(agent_id) do
    Repo.all(from(g in Gate, where: g.agent_id == ^agent_id and g.status == "open"))
  end

  @doc """
  Boot-time reconciliation: unresolved routine gates become RESTART NOTICE
  inbox notes (then `requeued`); unresolved non-routine gates are `orphaned`.
  Idempotent: only `open` rows are touched.
  """
  def reconcile! do
    routine_ids = Enum.map(Custode.Routine.all(), & &1.id)

    for gate <- Repo.all(from(g in Gate, where: g.status == "open")) do
      if gate.agent_id in routine_ids do
        requeue!(gate)
      else
        update_status!(gate, "orphaned")
      end
    end

    :ok
  end

  defp open(agent_id, state) do
    {kind, action_id, detail} =
      case ObanClaude.Agent.status(agent_id) do
        {:ok, {:awaiting_permission, %{id: id, description: description}}} ->
          {"approval", id, description}

        {:ok, {:waiting_for_user, question}} ->
          {"question", nil, question}

        _other ->
          {to_string(state), nil, nil}
      end

    Repo.insert!(%Gate{agent_id: agent_id, kind: kind, action_id: action_id, detail: detail})
  end

  defp resolve_open(agent_id) do
    Repo.update_all(
      from(g in Gate, where: g.agent_id == ^agent_id and g.status == "open"),
      set: [status: "resolved", updated_at: DateTime.utc_now()]
    )
  end

  defp requeue!(gate) do
    routine = Custode.Routine.get(gate.agent_id)
    inbox = routine.workspace |> Path.expand() |> Path.join("inbox")
    File.mkdir_p!(inbox)

    File.write!(Path.join(inbox, "restart-gate-#{gate.id}.md"), """
    RESTART NOTICE: before the last restart you had a pending #{gate.kind}:

    #{gate.detail || "(no detail recorded)"}

    If it is still relevant, re-raise it on this sweep
    (directive=request_permission or directive=ask_user). If it is moot,
    just journal that and move on.
    """)

    update_status!(gate, "requeued")
  end

  defp update_status!(gate, status) do
    gate |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end
end
