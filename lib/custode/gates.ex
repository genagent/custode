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

  alias Custode.Gates.Class
  alias Custode.Repo

  defmodule Gate do
    @moduledoc false
    use Ecto.Schema

    schema "gates" do
      field(:agent_id, :string)
      field(:kind, :string)
      field(:action_id, :string)
      field(:detail, :string)
      # the class of action an approval asks for (#451); see Custode.Gates.Class
      field(:class, :string)
      field(:status, :string, default: "open")
      # what was decided, by whom, from which surface, and why (#448). `status`
      # says the gate is over; these say how it ended.
      field(:outcome, :string)
      field(:decided_by, :string)
      field(:decided_via, :string)
      field(:reason, :string)
      # when an approved gate's continuation ended (#451); nil on an approved
      # row means its turn is still running and the grant is live
      field(:continuation_ended_at, :utc_datetime_usec)
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
  # :telemetry DETACHES a handler that raises -- one transient Repo/file
  # error would silently kill this pipeline until restart (audit
  # 2026-07-21). Never raise out of a handler.
  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      require Logger

      Logger.error(
        "Custode.Gates handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  defp do_handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    if meta.from in @gated do
      outcome = resolution(meta.from, meta.to)
      resolve_open(meta.agent_id, outcome)
      Custode.Feed.mark_gate_resolved(meta.agent_id, outcome)
    end

    # An approval is a live grant only while its continuation runs (#451).
    # The approve itself is awaiting_permission -> running, so this never
    # closes the grant it just opened.
    if meta.from == :running, do: end_continuations(meta.agent_id)

    if meta.to in @gated, do: open(meta.agent_id, meta.to)
    :ok
  end

  defp end_continuations(agent_id) do
    Repo.update_all(
      from(g in Gate,
        where:
          g.agent_id == ^agent_id and g.outcome == "approved" and
            is_nil(g.continuation_ended_at)
      ),
      set: [continuation_ended_at: DateTime.utc_now()]
    )
  end

  # what actually happened to the gated item, for the feed card's chip
  defp resolution(:awaiting_permission, :running), do: "approved"
  defp resolution(:awaiting_permission, :idle), do: "rejected"
  defp resolution(:waiting_for_user, _to), do: "answered"
  defp resolution(_from, :paused), do: "cleared by pause"
  defp resolution(_from, _to), do: "resolved"

  @doc "Open gates for an agent."
  def open_gates(agent_id) do
    Repo.all(from(g in Gate, where: g.agent_id == ^agent_id and g.status == "open"))
  end

  @doc """
  Every open gate, newest first, grouped by agent id (#296).

  One query for the whole fleet, so a page resolving attention for every
  agent does not issue one `open_gates/1` per tile. Unbounded on purpose: a
  limit here would silently drop agents from the needs-you group, which is
  the one group that must never under-report.
  """
  def open_by_agent do
    from(g in Gate, where: g.status == "open", order_by: [desc: g.id])
    |> Repo.all()
    |> Enum.group_by(& &1.agent_id)
  end

  @doc """
  Stamp a decision onto an agent's open gate before it is carried out (#448):
  who decided, from which surface, and why.

  Called BEFORE the engine call on purpose. The engine call causes the
  transition that resolves the row, so writing first means the row that gets
  resolved already says why. Returns how many rows it stamped; zero is not an
  error, because a decision can outrun the asynchronous insert of its gate row
  (#436), and the decision still has to go through.

  `action_id` narrows to one action when the caller has it. `nil` stamps the
  agent's open gates, which is one row in practice.
  """
  @spec record_decision(String.t(), String.t() | nil, keyword()) :: non_neg_integer()
  def record_decision(agent_id, action_id, opts) do
    query = from(g in Gate, where: g.agent_id == ^agent_id and g.status == "open")

    query =
      if action_id, do: from(g in query, where: g.action_id == ^action_id), else: query

    {count, _rows} =
      Repo.update_all(query,
        set: [
          decided_by: opts |> Keyword.get(:by, "operator") |> to_string(),
          decided_via: opts |> Keyword.get(:via) |> stringify(),
          reason: Keyword.get(opts, :reason)
        ]
      )

    count
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  @doc """
  How often each agent's approval gates are approved (#448): approved and
  rejected counts and the rate, busiest first. Gates with no recorded outcome
  are left out of the rate, not counted as either.

  This is the number that says whether a gate class is a decision or a
  formality, which is what relaxing one (or handing it to the caretaker,
  #451) should rest on.
  """
  @spec approval_rates() :: [
          %{agent_id: String.t(), approved: integer(), rejected: integer(), rate: float()}
        ]
  def approval_rates do
    from(g in Gate,
      where: g.kind == "approval" and g.outcome in ["approved", "rejected"],
      group_by: g.agent_id,
      select: %{
        agent_id: g.agent_id,
        approved: fragment("SUM(CASE WHEN ? = 'approved' THEN 1 ELSE 0 END)", g.outcome),
        rejected: fragment("SUM(CASE WHEN ? = 'rejected' THEN 1 ELSE 0 END)", g.outcome)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row -> Map.put(row, :rate, row.approved / (row.approved + row.rejected)) end)
    |> Enum.sort_by(&{-(&1.approved + &1.rejected), &1.agent_id})
  end

  @typedoc "An approved gate whose continuation is still running."
  @type grant :: %{gate_id: integer(), class: String.t() | nil, detail: String.t() | nil}

  @doc """
  The agent's live grant (#451): its approved gate whose continuation has not
  ended, or `nil`. `Custode.Gates.Grant` judges a write verb against it.
  """
  @spec active_grant(String.t()) :: grant() | nil
  def active_grant(agent_id) do
    Repo.one(
      from(g in Gate,
        where:
          g.agent_id == ^agent_id and g.kind == "approval" and g.outcome == "approved" and
            is_nil(g.continuation_ended_at),
        order_by: [desc: g.id],
        limit: 1,
        select: %{gate_id: g.id, class: g.class, detail: g.detail}
      )
    )
  end

  @doc """
  The approval rate per gate CLASS (#451), in `Custode.Gates.Class` order, with
  the median minutes a gate of that class waited for its decision.

  Only gates that declared a class are here: the rows from before the field,
  and from agents that never say, are in `approval_rates/0` and nowhere else.
  The wait is beside the rate on purpose. A class at 100% that also waits
  hours is the one whose gate costs the most and decides the least.
  """
  @spec approval_rates_by_class() :: [
          %{
            class: String.t(),
            approved: integer(),
            rejected: integer(),
            rate: float(),
            median_wait_min: float()
          }
        ]
  def approval_rates_by_class do
    rows =
      Repo.all(
        from(g in Gate,
          where:
            g.kind == "approval" and g.outcome in ["approved", "rejected"] and
              not is_nil(g.class),
          select: {g.class, g.outcome, g.inserted_at, g.updated_at}
        )
      )

    by_class = Enum.group_by(rows, &elem(&1, 0))

    for class <- Class.ids(), decided = Map.get(by_class, class), decided != nil do
      approved = Enum.count(decided, &(elem(&1, 1) == "approved"))
      waits = Enum.map(decided, fn {_c, _o, opened, closed} -> DateTime.diff(closed, opened) end)

      %{
        class: class,
        approved: approved,
        rejected: length(decided) - approved,
        rate: approved / length(decided),
        median_wait_min: Float.round(median(waits) / 60, 1)
      }
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  @doc "Recent gates fleet-wide, newest first, optionally filtered by status."
  def recent(limit \\ 20, status \\ nil) do
    query = from(g in Gate, order_by: [desc: g.id], limit: ^limit)

    query =
      case status do
        nil -> query
        status -> from(g in query, where: g.status == ^status)
      end

    Repo.all(query)
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

    Repo.insert!(%Gate{
      agent_id: agent_id,
      kind: kind,
      action_id: action_id,
      detail: detail,
      class: declared_class(agent_id, kind)
    })
  end

  # The engine carries only the action's description, so the class the agent
  # declared is read from the turn that raised the gate. That turn's feed
  # entry is written on `[:oban_claude, :run, :stop]`, which the worker emits
  # BEFORE it casts `job_finished`, so it is there by the time the transition
  # that brought us here fires. A turn that did not raise this gate (an older
  # entry, a different directive) declares nothing.
  defp declared_class(agent_id, "approval") do
    case Custode.Feed.recent_by_event("turn", agent: agent_id, limit: 1) do
      [%{"directive" => "request_permission", "action_class" => class}] -> Class.normalize(class)
      _none -> nil
    end
  end

  defp declared_class(_agent_id, _kind), do: nil

  # The outcome goes on the row as well as the feed card (#448): the card is
  # JSON inside a feed entry, which nothing can aggregate over.
  defp resolve_open(agent_id, outcome) do
    Repo.update_all(
      from(g in Gate, where: g.agent_id == ^agent_id and g.status == "open"),
      set: [status: "resolved", outcome: outcome, updated_at: DateTime.utc_now()]
    )
  end

  defp requeue!(gate) do
    routine = Custode.Routine.get(gate.agent_id)

    {:ok, _path} =
      Custode.Inbox.drop(routine, "restart-gate-#{gate.id}.md", """
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
