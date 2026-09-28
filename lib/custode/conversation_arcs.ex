defmodule Custode.ConversationArcs do
  @moduledoc """
  Custode-owned continuation policy and durable history for provider sessions.

  Provider session ids are local accelerators. This module selects an exact
  named arc before delivery, records why it chose fresh or resume, and updates
  the durable row from the wrappers' completion telemetry.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Custode.{ConversationArc, ConversationArcEvent, Repo, Routine}

  @events [
    [:oban_claude, :agent, :turn_completed],
    [:oban_codex, :agent, :turn_completed]
  ]

  @resumable_kinds ~w(operator specialist)

  @type decision :: %{
          arc: ConversationArc.t(),
          arc_id: String.t(),
          decision: :fresh | :fresh_fallback | :resume,
          reason: atom(),
          session: :fresh | :fresh_fallback | :resume,
          session_arcs: %{optional(String.t()) => String.t()}
        }

  @doc "Prepare and record a continuation decision before a provider launch."
  @spec prepare(map(), atom(), keyword()) :: {:ok, decision()} | {:error, term()}
  def prepare(routine, kind, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    logical_id = Keyword.get(opts, :arc_id) || default_logical_id(kind)
    facts = compatibility(routine)

    Repo.transaction(
      fn -> prepare_transaction(routine, to_string(kind), logical_id, facts, now) end,
      mode: :immediate
    )
    |> case do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Add the selected arc and compatible seed handles to provider Tick args."
  def tick_args(routine, kind, opts \\ []) do
    with {:ok, prepared} <- prepare(routine, kind, opts) do
      tick_session =
        if kind in [:scheduled, :job, :attempt, :inbox] or
             prepared.session == :fresh_fallback,
           do: :fresh,
           else: prepared.session

      args =
        routine
        |> Routine.tick_args()
        |> Map.put("arc_id", prepared.arc_id)
        |> Map.put("session", Atom.to_string(tick_session))
        |> put_in(["start", "session_arcs"], seed_map(routine))

      {:ok, args, prepared}
    end
  end

  @doc "Compatible active provider handles used when a provider process starts cold."
  def seed_map(routine) do
    facts = compatibility(routine)

    Repo.all(
      from(a in ConversationArc,
        where:
          a.routine_id == ^routine.id and a.state == "active" and
            a.kind in ^@resumable_kinds and
            a.provider == ^facts.provider and a.host_id == ^facts.host_id and
            a.workspace_identity == ^facts.workspace_identity and
            a.configuration_fingerprint == ^facts.configuration_fingerprint and
            not is_nil(a.provider_session_id),
        select: {a.arc_id, a.provider_session_id}
      )
    )
    |> Map.new()
  end

  @doc "Prepare an operator turn and add a durable-context recovery instruction when needed."
  def operator_delivery(routine, prompt) do
    with {:ok, prepared} <- prepare(routine, :operator) do
      opts = [arc_id: prepared.arc_id, session: prepared.session, origin: :operator]
      {:ok, recovery_prompt(routine, prompt, prepared), opts}
    end
  end

  @doc "Current durable arc state for MCP and LiveView."
  def read_model(routine_id) do
    arcs =
      Repo.all(
        from(a in ConversationArc,
          where: a.routine_id == ^routine_id and a.state == "active",
          order_by: [desc: a.last_used_at]
        )
      )

    current = Enum.find(arcs, &(&1.kind == "operator")) || List.first(arcs)

    %{
      current: project(current),
      arcs: Enum.map(arcs, &project/1)
    }
  end

  @doc "All generations for one logical arc, oldest first."
  def history(routine_id, logical_id) do
    Repo.all(
      from(a in ConversationArc,
        where: a.routine_id == ^routine_id and a.logical_id == ^logical_id,
        order_by: [asc: a.opened_at],
        preload: [:events]
      )
    )
  end

  @doc "Close an assignment arc after its durable result is complete."
  def complete(routine_id, logical_id, reason \\ :completed) do
    close_active(routine_id, logical_id, "completed", to_string(reason))
  end

  @doc "Explicitly rotate an arc before its next turn."
  def rotate(routine_id, logical_id, reason \\ :operator_requested) do
    close_active(routine_id, logical_id, "rotated", to_string(reason))
  end

  @doc "Close an arc whose provider launch was not admitted."
  def abandon(%{arc: %ConversationArc{} = arc}, reason) do
    Repo.transaction(fn -> close!(arc, "completed", to_string(reason), "launch_failed") end)
  end

  @doc false
  def attach do
    :telemetry.attach_many("custode-conversation-arcs", @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([provider, :agent, :turn_completed], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    record_completion(provider, meta)
  rescue
    exception ->
      Logger.error(
        "Custode.ConversationArcs handler error (kept attached): " <>
          Exception.message(exception)
      )

      :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp prepare_transaction(routine, kind, logical_id, facts, now) do
    existing = active(routine.id, logical_id)

    case existing && incompatibility(existing, facts) do
      nil -> select_or_create(existing, routine.id, kind, logical_id, facts, now)
      reason -> rotate_and_create(existing, routine.id, kind, logical_id, facts, now, reason)
    end
  end

  defp select_or_create(nil, routine_id, kind, logical_id, facts, now) do
    create_arc(routine_id, kind, logical_id, facts, now, nil, :fresh, :no_session)
  end

  defp select_or_create(%ConversationArc{} = arc, _routine_id, kind, _arc_id, _facts, now) do
    {decision, reason} = continuation_for(arc, kind)
    arc = update_decision!(arc, decision, reason, now)
    record_decision!(arc, decision, reason)
    result(arc, decision, reason)
  end

  defp rotate_and_create(old, routine_id, kind, logical_id, facts, now, reason) do
    old
    |> ConversationArc.update_changeset(%{
      state: "rotated",
      rotation_reason: to_string(reason),
      closed_at: now,
      last_used_at: now
    })
    |> Repo.update!()

    record_event!(old, %{kind: "rotation", reason: to_string(reason)})
    create_arc(routine_id, kind, logical_id, facts, now, old.id, :fresh, reason)
  end

  defp create_arc(routine_id, kind, logical_id, facts, now, parent_id, decision, reason) do
    arc =
      %{
        routine_id: routine_id,
        arc_id: provider_arc_id(logical_id),
        logical_id: logical_id,
        kind: kind,
        provider: facts.provider,
        host_id: facts.host_id,
        workspace_identity: facts.workspace_identity,
        configuration_fingerprint: facts.configuration_fingerprint,
        parent_id: parent_id,
        state: "active",
        last_decision: to_string(decision),
        last_reason: to_string(reason),
        opened_at: now,
        last_used_at: now
      }
      |> ConversationArc.create_changeset()
      |> Repo.insert!()

    record_decision!(arc, decision, reason)
    result(arc, decision, reason)
  end

  defp update_decision!(arc, decision, reason, now) do
    arc
    |> ConversationArc.update_changeset(%{
      last_decision: to_string(decision),
      last_reason: to_string(reason),
      last_used_at: now
    })
    |> Repo.update!()
  end

  defp continuation_for(%{last_outcome: "session_rejected"}, _kind),
    do: {:fresh_fallback, :resume_failed}

  defp continuation_for(%{provider_session_id: session_id}, kind)
       when is_binary(session_id) and kind in @resumable_kinds,
       do: {:resume, :session_available}

  defp continuation_for(_arc, _kind), do: {:fresh, :no_session}

  defp result(arc, decision, reason) do
    session_arcs =
      if decision == :resume and is_binary(arc.provider_session_id),
        do: %{arc.arc_id => arc.provider_session_id},
        else: %{}

    %{
      arc: arc,
      arc_id: arc.arc_id,
      decision: decision,
      reason: reason,
      session: delivery_session(decision, reason),
      session_arcs: session_arcs
    }
  end

  # A first operator message asks the live wrapper to resume the named arc.
  # If it queued behind an earlier turn that creates the handle, the wrapper
  # can then use it; without one, the wrapper records the actual fresh choice.
  defp delivery_session(:fresh, :no_session), do: :resume
  defp delivery_session(decision, _reason), do: decision

  defp recovery_prompt(routine, prompt, %{decision: :fresh_fallback}) do
    """
    [Custode continuity recovery]
    The exact provider session for this conversation was rejected. Reconstruct
    the needed context from Custode-owned records before answering: recall the
    `#{routine.id}` notebook and inspect its journal, todos, open gates and
    current workspace state. Do not select a different provider transcript.

    Operator message:
    #{prompt}
    """
  end

  defp recovery_prompt(_routine, prompt, _prepared), do: prompt

  defp active(routine_id, logical_id) do
    Repo.one(
      from(a in ConversationArc,
        where:
          a.routine_id == ^routine_id and a.logical_id == ^logical_id and a.state == "active",
        limit: 1
      )
    )
  end

  defp close_active(routine_id, logical_id, state, reason) do
    case active(routine_id, logical_id) do
      nil -> {:error, :not_found}
      arc -> close(arc, state, reason)
    end
  end

  defp close(arc, state, reason) do
    Repo.transaction(fn -> close!(arc, state, reason, state) end)
  end

  defp close!(arc, state, reason, event_kind) do
    now = DateTime.utc_now()

    updated =
      arc
      |> ConversationArc.update_changeset(%{
        state: state,
        rotation_reason: reason,
        last_outcome:
          if(event_kind == "launch_failed", do: "not_launched", else: arc.last_outcome),
        closed_at: now,
        last_used_at: now
      })
      |> Repo.update!()

    record_event!(updated, %{kind: event_kind, reason: reason, outcome: updated.last_outcome})
    updated
  end

  defp compatibility(routine) do
    %{
      provider: to_string(routine.provider),
      host_id: host_id(),
      workspace_identity: Path.expand(routine.working_dir),
      configuration_fingerprint: fingerprint(Routine.continuation_contract(routine))
    }
  end

  defp incompatibility(arc, facts) do
    cond do
      arc.provider != facts.provider -> :provider_changed
      arc.host_id != facts.host_id -> :host_changed
      arc.workspace_identity != facts.workspace_identity -> :workspace_changed
      arc.configuration_fingerprint != facts.configuration_fingerprint -> :configuration_changed
      true -> nil
    end
  end

  defp fingerprint(contract) do
    contract
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp host_id do
    Application.get_env(:custode, :conversation_host_id) || system_host_id()
  end

  defp system_host_id do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  defp default_logical_id(:operator), do: "operator"

  defp default_logical_id(kind) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{kind}:#{suffix}"
  end

  defp provider_arc_id(logical_id) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    String.slice(logical_id, 0, 238) <> ":" <> suffix
  end

  defp record_completion(provider, meta) do
    provider = provider |> Atom.to_string() |> String.replace_prefix("oban_", "")

    result =
      Repo.transaction(
        fn ->
          case completion_arc(meta.agent_id, meta.arc_id, provider) do
            nil -> :ok
            arc -> update_from_completion(arc, meta)
          end
        end,
        mode: :immediate
      )

    if match?({:error, _reason}, result) do
      Logger.error("could not persist conversation completion: #{inspect(result)}")
    end

    :ok
  end

  defp completion_arc(routine_id, arc_id, provider) do
    Repo.one(
      from(a in ConversationArc,
        where: a.routine_id == ^routine_id and a.arc_id == ^arc_id and a.provider == ^provider,
        order_by: [desc: a.opened_at],
        limit: 1
      )
    )
  end

  defp update_from_completion(arc, meta) do
    now = DateTime.utc_now()
    outcome = to_string(meta.outcome)
    rejected? = outcome == "session_rejected"
    session_id = if rejected?, do: nil, else: meta.session_id

    attrs = %{
      provider_session_id: session_id,
      last_decision: to_string(meta.continuation_decision),
      last_reason: to_string(meta.continuation_reason),
      last_outcome: outcome,
      last_used_at: now
    }

    arc = arc |> ConversationArc.update_changeset(attrs) |> Repo.update!()

    record_event!(arc, %{
      kind: "completion",
      decision: to_string(meta.continuation_decision),
      reason: to_string(meta.continuation_reason),
      outcome: outcome,
      provider_session_id: session_id,
      details: %{"outcome_reason" => inspect(meta.outcome_reason, limit: 10)}
    })

    if arc.kind in ["scheduled", "job", "attempt", "inbox"] do
      close!(arc, "completed", "turn_#{outcome}", "completed")
    end
  end

  defp record_decision!(arc, decision, reason) do
    record_event!(arc, %{
      kind: "decision",
      decision: to_string(decision),
      reason: to_string(reason),
      provider_session_id: arc.provider_session_id
    })
  end

  defp record_event!(arc, attrs) do
    attrs
    |> Map.put(:conversation_arc_id, arc.id)
    |> Map.put_new(:details, %{})
    |> ConversationArcEvent.changeset()
    |> Repo.insert!()
  end

  defp project(nil), do: nil

  defp project(arc) do
    %{
      arc_id: arc.arc_id,
      logical_id: arc.logical_id,
      kind: arc.kind,
      provider: arc.provider,
      provider_session_id: arc.provider_session_id,
      host_id: arc.host_id,
      workspace_identity: arc.workspace_identity,
      configuration_fingerprint: arc.configuration_fingerprint,
      state: arc.state,
      decision: arc.last_decision,
      reason: arc.last_reason,
      outcome: arc.last_outcome,
      opened_at: arc.opened_at,
      last_used_at: arc.last_used_at
    }
  end
end
