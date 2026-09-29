defmodule Custode.ProviderJobs do
  @moduledoc """
  Durable Oban ownership facts for routine provider work.

  A provider agent process is the in-memory owner of a turn, but the provider
  job can outlive that process. A replacement must therefore treat any active
  job for the same agent id as physical work still in flight, even when both
  provider registries report the agent offline.

  Provider Tick jobs are a separate, short-lived admission layer. Their
  embedded delivery contract may become stale while they wait in `:ticks`.
  `fence_stale_ticks/3` removes every not-yet-running Tick whose provider or
  delivery revision no longer matches the current routine and reports any
  executing adapter that still owns the admission boundary.

  The `:agents` queue is withheld at boot until active Codex turn jobs have
  their captured Custode bearer credential refreshed. The rest of each job's
  captured provider contract stays unchanged at the Elixir term level; only
  the authorization override changes.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{ConversationArcs, OperatorMessages, Repo, Routine}
  alias Custode.MCP.Identity

  @active_states ~w(available scheduled executing retryable suspended)
  @turn_workers ["ObanClaude.Agent.Job", "ObanCodex.Agent.Job"]
  @tick_workers ["ObanClaude.Agent.Tick", "ObanCodex.Agent.Tick"]
  @codex_turn_worker "ObanCodex.Agent.Job"
  @codex_authorization_prefix "mcp_servers.custode.http_headers.Authorization="
  @default_queues [agents: 5, ticks: 1, sensors: 2, workflows: 1]

  defmodule BootStarter do
    @moduledoc false

    @doc false
    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]},
        restart: :temporary,
        type: :worker
      }
    end

    # Keep this work synchronous with supervision startup. Returning only
    # after the credential rewrite and queue signal means a rewrite failure
    # stops boot with :agents still withheld.
    @doc false
    def start_link(opts) do
      reconfigure =
        Keyword.get(opts, :reconfigure, &Custode.AgentHandoff.reconfigure/2)

      refresh =
        Keyword.get(
          opts,
          :refresh_credentials,
          &Custode.ProviderJobs.refresh_codex_credentials!/0
        )

      reconcile_removed =
        Keyword.get(
          opts,
          :reconcile_removed,
          &Custode.ProviderJobs.reconcile_removed_routines!/0
        )

      reconcile_legacy =
        Keyword.get(
          opts,
          :reconcile_legacy,
          &Custode.ProviderJobs.reconcile_legacy_turns!/0
        )

      start_queue =
        Keyword.get(opts, :start_agents_queue, &Custode.ProviderJobs.start_agents_queue!/0)

      result =
        reconfigure.([], fn ->
          :ok = reconcile_removed.()
          :ok = reconcile_legacy.()
          :ok = refresh.()
          :ok = start_queue.()
          {:ok, :agents_queue_started}
        end)

      case result do
        {:ok, :agents_queue_started} ->
          :ignore

        other ->
          raise "could not open the agents queue at the configuration boundary: #{inspect(other)}"
      end
    end
  end

  @doc false
  def initial_queues do
    configured_queues()
    |> Keyword.delete(:ticks)
    |> Keyword.delete(:agents)
  end

  @doc false
  def agents_queue_options do
    case Keyword.fetch(configured_queues(), :agents) do
      :error ->
        nil

      {:ok, limit} when is_integer(limit) and limit > 0 ->
        [queue: :agents, limit: limit]

      {:ok, opts} when is_list(opts) ->
        Keyword.put(opts, :queue, :agents)
    end
  end

  @doc false
  def start_agents_queue! do
    case agents_queue_options() do
      nil ->
        :ok

      opts ->
        case Oban.start_queue(opts) do
          :ok ->
            :ok

          {:error, reason} ->
            raise "could not start the agents queue: #{inspect(reason)}"
        end
    end
  end

  @doc "Refresh the Custode bearer credential captured by every active Codex turn job."
  @spec refresh_codex_credentials!() :: :ok
  def refresh_codex_credentials! do
    Repo.transaction(&refresh_active_codex_credentials!/0)
    |> finish_credential_refresh!()
  end

  @doc "Active durable provider turns for `agent_id`, oldest first."
  @spec active_turns(String.t()) :: [Oban.Job.t()]
  def active_turns(agent_id) when is_binary(agent_id) do
    Repo.all(from(j in active_turn_query(agent_id), order_by: [asc: j.id]))
  end

  @doc "Whether durable provider work still owns the physical turn boundary."
  @spec active_turn?(String.t()) :: boolean()
  def active_turn?(agent_id) when is_binary(agent_id) do
    agent_id |> active_turn_query() |> Repo.exists?()
  end

  @doc """
  Cancel every admitted provider turn for an agent during cold-boot spend reconciliation.

  This is a boot-only fence. The `:agents` queue is withheld and the instance
  guard has excluded another Custode node before it runs, so an `executing`
  row is stale durable ownership rather than a live executor. Oban cancellation
  is only an asynchronous signal against a live executor and is not a safe
  runtime handoff boundary.
  """
  @spec cancel_active_turns!(String.t()) :: :ok
  def cancel_active_turns!(agent_id) when is_binary(agent_id) do
    {:ok, _count} = Oban.cancel_all_jobs(active_turn_query(agent_id))

    if active_turn?(agent_id) do
      raise "active provider turns remain after cancellation for #{inspect(agent_id)}"
    else
      :ok
    end
  end

  @doc """
  Cancel provider work whose owner is absent from the booted roster.

  Both provider queues are withheld while this runs. That makes every active
  row durable work without a live executor, including rows left in
  `executing` by a hard stop. Cancellation is followed by operator-message
  reconciliation so every accepted submission receives a terminal outcome;
  active messages without any durable job are refused explicitly.
  """
  @spec reconcile_removed_routines!() :: :ok
  def reconcile_removed_routines! do
    configured_ids = Routine.all() |> Enum.map(& &1.id) |> MapSet.new()

    orphaned_jobs =
      active_provider_jobs()
      |> Enum.reject(&configured_job?(&1, configured_ids))

    Enum.each(orphaned_jobs, fn job -> :ok = Oban.cancel_job(job) end)

    :ok = abandon_cancelled_ticks(orphaned_jobs, :routine_removed)

    remaining =
      active_provider_jobs()
      |> Enum.reject(&configured_job?(&1, configured_ids))

    if remaining != [] do
      raise "orphaned provider work remains after boot cancellation: #{inspect(Enum.map(remaining, & &1.id))}"
    end

    :ok = settle_removed_targets(configured_ids)
    :ok = OperatorMessages.reconcile!()

    :ok
  end

  @doc "Cancel configured pre-revision turns before the withheld agents queue opens."
  @spec reconcile_legacy_turns!() :: :ok
  def reconcile_legacy_turns! do
    configured_ids = Routine.all() |> Enum.map(& &1.id) |> MapSet.new()

    legacy_jobs =
      active_turn_jobs()
      |> Enum.filter(&legacy_configured_turn?(&1, configured_ids))

    Enum.each(legacy_jobs, fn job -> :ok = Oban.cancel_job(job) end)

    remaining =
      active_turn_jobs()
      |> Enum.filter(&legacy_configured_turn?(&1, configured_ids))

    if remaining != [] do
      raise "legacy provider work remains after boot cancellation: #{inspect(Enum.map(remaining, & &1.id))}"
    end

    if legacy_jobs != [], do: OperatorMessages.reconcile!(), else: :ok
  end

  @doc """
  Fence provider Tick adapters that carry an obsolete delivery contract.

  The current provider is part of the delivery revision, but checking the
  worker as well makes the provider switch explicit and also fences legacy
  jobs that have no revision. Not-yet-running jobs are cancelled. An executing
  Tick is returned instead: Oban cancellation only signals an executor and
  does not wait for it to stop, so treating cancellation as a safe boundary
  would let a replacement race the old adapter's side effects.
  """
  @spec fence_stale_ticks(String.t(), :claude | :codex, String.t()) ::
          {:ok, %{cancelled: non_neg_integer(), executing: [Oban.Job.t()]}}
  def fence_stale_ticks(agent_id, provider, delivery_revision)
      when is_binary(agent_id) and is_binary(delivery_revision) and delivery_revision != "" and
             provider in [:claude, :codex] do
    desired_worker = tick_worker(provider)

    stale = stale_tick_query(agent_id, desired_worker, delivery_revision)

    cancellable = from(j in stale, where: j.state != "executing")
    candidates = Repo.all(cancellable)
    {:ok, cancelled} = Oban.cancel_all_jobs(cancellable)
    :ok = abandon_cancelled_ticks(candidates, :stale_tick)

    # Re-read after cancellation so a job claimed between the first query and
    # the update is observed as executing rather than silently escaping.
    executing = Repo.all(from(j in stale, where: j.state == "executing", order_by: [asc: j.id]))

    {:ok, %{cancelled: cancelled, executing: executing}}
  end

  defp stale_tick_query(agent_id, desired_worker, delivery_revision) do
    from(j in Oban.Job,
      where: j.worker in ^@tick_workers,
      where: j.state in ^@active_states,
      where: fragment("json_extract(?, '$.agent_id') = ?", j.args, ^agent_id),
      where:
        j.worker != ^desired_worker or
          fragment(
            "coalesce(json_extract(?, '$.delivery_revision'), '') != ?",
            j.args,
            ^delivery_revision
          )
    )
  end

  defp active_turn_query(agent_id) do
    from(j in Oban.Job,
      where: j.worker in ^@turn_workers,
      where: j.state in ^@active_states,
      where: fragment("json_extract(?, '$.agent_id') = ?", j.meta, ^agent_id)
    )
  end

  defp active_provider_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker in ^(@turn_workers ++ @tick_workers),
        where: j.state in ^@active_states,
        order_by: [asc: j.id]
      )
    )
  end

  defp active_turn_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker in ^@turn_workers,
        where: j.state in ^@active_states,
        order_by: [asc: j.id]
      )
    )
  end

  defp legacy_configured_turn?(job, configured_ids) do
    configured_job?(job, configured_ids) and job.meta["config_revision"] in [nil, ""]
  end

  defp abandon_cancelled_ticks(jobs, reason) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      case abandon_cancelled_tick(Repo.get(Oban.Job, job.id), reason) do
        :ok ->
          {:cont, :ok}

        {:error, cleanup_reason} ->
          {:halt, {:error, {:conversation_arc_cleanup, job.id, cleanup_reason}}}
      end
    end)
  end

  defp abandon_cancelled_tick(
         %Oban.Job{
           state: "cancelled",
           worker: worker,
           args: %{"agent_id" => agent_id, "arc_id" => arc_id}
         },
         reason
       )
       when worker in @tick_workers and is_binary(agent_id) and is_binary(arc_id) and
              arc_id != "" do
    case ConversationArcs.abandon(agent_id, arc_id, reason) do
      {:ok, _arc_or_already_closed} -> :ok
      {:error, cleanup_reason} -> {:error, cleanup_reason}
    end
  end

  defp abandon_cancelled_tick(_not_a_cancelled_arc_tick, _reason), do: :ok

  defp settle_removed_targets(configured_ids) do
    OperatorMessages.active_target_ids()
    |> Enum.reject(&MapSet.member?(configured_ids, &1))
    |> Enum.each(&OperatorMessages.settle_removed/1)

    :ok
  end

  defp configured_job?(job, configured_ids) do
    case provider_agent_id(job) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        MapSet.member?(configured_ids, agent_id)

      _missing ->
        false
    end
  end

  defp provider_agent_id(%Oban.Job{worker: worker, meta: meta})
       when worker in @turn_workers,
       do: meta["agent_id"]

  defp provider_agent_id(%Oban.Job{worker: worker, args: args})
       when worker in @tick_workers,
       do: args["agent_id"]

  defp configured_queues do
    Application.get_env(:custode, :oban_queues, @default_queues)
  end

  defp refresh_active_codex_credentials! do
    from(j in Oban.Job,
      where: j.worker == ^@codex_turn_worker,
      where: j.state in ^@active_states,
      order_by: [asc: j.id]
    )
    |> Repo.all()
    |> Enum.count(&(refresh_codex_credential!(&1) == :cancelled))
  end

  defp finish_credential_refresh!({:ok, 0}), do: :ok

  defp finish_credential_refresh!({:ok, _cancelled}) do
    # Operator-message reconciliation ran earlier in the boot tree while
    # these jobs were still active. Project the deterministic cancellation
    # before any provider work can execute.
    configured_ids = Routine.all() |> Enum.map(& &1.id) |> MapSet.new()
    :ok = settle_removed_targets(configured_ids)
    OperatorMessages.reconcile!()
  end

  defp finish_credential_refresh!({:error, reason}) do
    raise "could not refresh active Codex credentials: #{inspect(reason)}"
  end

  defp refresh_codex_credential!(%Oban.Job{args: args} = job) do
    case Map.fetch(args, "config_overrides") do
      :error -> :ok
      {:ok, overrides} -> refresh_codex_overrides!(job, overrides)
    end
  end

  defp refresh_codex_overrides!(job, overrides) when is_list(overrides) do
    if Enum.any?(overrides, &authorization_override?/1),
      do: refresh_authorized_job!(job, overrides),
      else: :ok
  end

  defp refresh_codex_overrides!(job, other) do
    raise "active Codex job #{job.id} has invalid config_overrides: #{inspect(other)}"
  end

  defp refresh_authorized_job!(job, overrides) do
    refresh_authorized_job!(job, overrides, current_routine_token!(job))
  end

  defp refresh_authorized_job!(job, overrides, {:ok, token}) do
    authorization = @codex_authorization_prefix <> Jason.encode!("Bearer " <> token)

    overrides =
      Enum.map(overrides, fn override ->
        if authorization_override?(override), do: authorization, else: override
      end)

    # config_revision remains the revision captured when the provider process
    # admitted this turn. A separate non-secret fingerprint records the
    # boot-only credential repair without falsely relabelling older semantic
    # args as the current roster.
    meta = Map.put(job.meta, "credential_revision", credential_revision(token))

    job
    |> Ecto.Changeset.change(
      args: Map.put(job.args, "config_overrides", overrides),
      meta: meta
    )
    |> Repo.update!()

    :ok
  end

  defp refresh_authorized_job!(job, _overrides, :orphan) do
    :ok = Oban.cancel_job(job)
    :cancelled
  end

  defp current_routine_token!(%Oban.Job{id: job_id, meta: %{"agent_id" => agent_id}})
       when is_binary(agent_id) and agent_id != "" do
    case Routine.get(agent_id) do
      nil ->
        :orphan

      %{} ->
        case Identity.token(:routine, agent_id) do
          {:ok, token} ->
            {:ok, token}

          :error ->
            raise "active Codex job #{job_id} cannot refresh the credential for configured routine #{inspect(agent_id)}"
        end
    end
  end

  defp current_routine_token!(%Oban.Job{}) do
    :orphan
  end

  defp credential_revision(token) do
    token
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp authorization_override?(override) when is_binary(override),
    do: String.starts_with?(override, @codex_authorization_prefix)

  defp authorization_override?(_override), do: false

  defp tick_worker(:claude), do: "ObanClaude.Agent.Tick"
  defp tick_worker(:codex), do: "ObanCodex.Agent.Tick"
end
