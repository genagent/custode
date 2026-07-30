defmodule Custode.AttemptPool do
  @moduledoc """
  Capability and policy admission for durable Attempt delivery.

  The pool never owns work lifecycle. It loads an Attempt and its immutable
  ContextBundle, selects one declared worker deterministically, and checks
  capacity, spend, lease, and cancellation immediately before physical
  delivery. Oban retries keep the same Attempt ID.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Attempt,
    Attempts,
    AttemptWorker,
    AttemptWorkerRegistry,
    ContextBundles,
    Executor,
    Repo,
    SpendLedger,
    WorkItems,
    WorkPolicy,
    WorkspaceLeases
  }

  alias Custode.Operations.WorkItems.Transition

  @live_job_states ~w(available scheduled executing retryable suspended)
  @model_features ~w(cancellation heartbeat structured_output timeout)

  defmodule Refusal do
    @moduledoc "Typed worker-pool refusal or retry decision."

    @enforce_keys [:kind, :code, :message, :details]
    defstruct @enforce_keys ++ [retry_after_ms: nil]

    @type kind :: :blocked | :retry | :cancelled

    @type t :: %__MODULE__{
            kind: kind(),
            code: String.t(),
            message: String.t(),
            details: map(),
            retry_after_ms: pos_integer() | nil
          }

    @spec render(t()) :: map()
    def render(%__MODULE__{} = refusal) do
      %{
        kind: Atom.to_string(refusal.kind),
        code: refusal.code,
        message: refusal.message,
        details: refusal.details,
        retry_after_ms: refusal.retry_after_ms
      }
    end
  end

  @type admission :: %{
          worker: AttemptWorker.t(),
          requirements: AttemptWorker.requirements(),
          policy: map()
        }

  @type admission_result ::
          {:ok, admission()}
          | {:blocked, Refusal.t()}
          | {:retry, Refusal.t()}
          | {:cancelled, Refusal.t()}
          | {:error, term()}

  @doc "Select and authorize one worker without launching an effect."
  @spec admit(map() | String.t(), keyword()) :: admission_result()
  def admit(attempt_or_id, options \\ []) do
    registry = Keyword.get(options, :worker_registry, AttemptWorkerRegistry.default())

    with {:ok, attempt, command} <- load_attempt(attempt_or_id),
         :ok <- dispatch_state(attempt),
         :ok <- posture_policy(attempt),
         {:ok, body} <- ContextBundles.body(attempt.context_bundle),
         {:ok, requirements} <- requirements(attempt, command, body),
         {:ok, worker} <- select_worker(registry, requirements),
         :ok <- lease_policy(attempt, requirements, options),
         {:ok, spend} <- spend_policy(attempt, body, options),
         {:ok, concurrency} <- concurrency_policy(attempt, worker, options) do
      {:ok,
       %{
         worker: worker,
         requirements: requirements,
         policy: %{
           work_policy: get_in(attempt.provenance || %{}, ["work_policy"]),
           spend: spend,
           concurrency: concurrency
         }
       }}
    else
      {:blocked, %Refusal{} = refusal} -> {:blocked, refusal}
      {:retry, %Refusal{} = refusal} -> {:retry, refusal}
      {:cancelled, %Refusal{} = refusal} -> {:cancelled, refusal}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Recheck admission atomically and enqueue through the selected handler.

  The handler receives the existing immutable decision and only stable IDs
  cross the resulting Oban boundary.
  """
  @spec dispatch(map(), integer() | nil, keyword()) ::
          :ok
          | {:blocked, Refusal.t()}
          | {:retry, Refusal.t()}
          | {:cancelled, Refusal.t()}
          | {:error, term()}
  def dispatch(attempt, oban_job_id, options \\ []) when is_map(attempt) do
    case :global.trans({__MODULE__, :dispatch}, fn ->
           attempt
           |> admit(options)
           |> dispatch_admitted(attempt, oban_job_id, options)
         end) do
      {:aborted, reason} -> {:error, {:attempt_pool_lock_failed, reason}}
      result -> result
    end
  end

  @doc "Cancel one queued or running delivery without creating another Attempt."
  @spec cancel(String.t(), term(), keyword()) ::
          {:ok, Executor.Cancellation.t()} | {:error, term()}
  def cancel(attempt_id, reason, options \\ []) when is_binary(attempt_id) do
    case Attempts.get(attempt_id) do
      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt when attempt.state in ~w(succeeded partial blocked failed cancelled) ->
        {:ok,
         %Executor.Cancellation{
           attempt_id: attempt.attempt_id,
           status: :already_terminal,
           reason: reason,
           details: %{attempt_state: attempt.state}
         }}

      %Attempt{} = attempt ->
        with :ok <- cancel_delivery(attempt, options),
             {:ok, _cancelled} <-
               Attempts.finish(attempt.attempt_id, %{
                 state: "cancelled",
                 usage: attempt.usage,
                 outcome: %{
                   kind: "worker_pool_cancelled",
                   reason: inspect(reason),
                   proposal: cancellation_proposal(attempt)
                 }
               }) do
          {:ok,
           %Executor.Cancellation{
             attempt_id: attempt.attempt_id,
             status: :requested,
             reason: reason,
             details: %{oban_job_id: attempt.oban_job_id}
           }}
        end
    end
  end

  @doc "Detect abandoned running Attempts and move their WorkItems out of active."
  @spec reconcile(DateTime.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def reconcile(now \\ DateTime.utc_now(), options \\ []) do
    from(attempt in Attempt,
      where:
        attempt.state == "running" or
          (attempt.state == "failed" and attempt.error_class == "worker_lost"),
      order_by: [asc: attempt.inserted_at]
    )
    |> Repo.all()
    |> Enum.reduce_while({:ok, []}, fn attempt, {:ok, recovered} ->
      reconcile_attempt(attempt, now, options, recovered)
    end)
    |> case do
      {:ok, recovered} -> {:ok, Enum.reverse(recovered)}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def reconcile! do
    case reconcile() do
      {:ok, recovered} -> recovered
      {:error, reason} -> raise "Attempt worker reconciliation failed: #{inspect(reason)}"
    end
  end

  @doc "Derive normalized scheduling requirements from immutable Attempt inputs."
  @spec requirements(Attempt.t(), String.t(), map()) ::
          {:ok, AttemptWorker.requirements()} | {:error, term()}
  def requirements(%Attempt{} = attempt, command, body)
      when is_binary(command) and is_map(body) do
    capabilities = value(body, :capabilities) || %{}
    repository_id = repository_id(attempt, body)

    requirements = %{
      command: command,
      executor_kind: attempt.executor_kind,
      provider: attempt.provider,
      repository_id: repository_id,
      tools: required_tools(capabilities),
      operations: string_list(value(capabilities, :operations)),
      isolation: isolation(command),
      features: required_features(attempt, capabilities)
    }

    if is_binary(repository_id) and repository_id != "",
      do: {:ok, requirements},
      else: {:error, :attempt_repository_required}
  end

  def requirements(_attempt, _command, _body), do: {:error, :invalid_attempt_requirements}

  defp dispatch_admitted(
         {:ok, %{worker: worker}},
         attempt,
         oban_job_id,
         options
       ) do
    case worker.handler.dispatch(attempt, oban_job_id, options) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_admitted(outcome, _attempt, _oban_job_id, _options),
    do: outcome

  defp reconcile_attempt(attempt, now, options, recovered) do
    attempt = Attempts.get(attempt.attempt_id)

    if attempt.state == "failed" do
      recover_terminal(attempt, recovered)
    else
      case lost_reason(attempt, now) do
        nil ->
          {:cont, {:ok, recovered}}

        reason ->
          recover_reconciled(attempt, reason, options, recovered)
      end
    end
  end

  defp recover_terminal(attempt, recovered) do
    work_item = WorkItems.get(attempt.work_item.work_item_id)

    if work_item.state == "active" and work_item.active_attempt_id == attempt.attempt_id do
      proposal = attempt.outcome |> value(:proposal) |> atomize_top()

      case recover_work_item(attempt, proposal) do
        {:ok, transition} ->
          result = %{
            attempt_id: attempt.attempt_id,
            work_item_id: work_item.work_item_id,
            reason: attempt.error_details,
            transition: transition
          }

          {:cont, {:ok, [result | recovered]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    else
      {:cont, {:ok, recovered}}
    end
  end

  defp recover_reconciled(attempt, reason, options, recovered) do
    case recover_lost(attempt, reason, options) do
      {:ok, result} -> {:cont, {:ok, [result | recovered]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp load_attempt(attempt_id) when is_binary(attempt_id),
    do: load_attempt(%{attempt_id: attempt_id})

  defp load_attempt(attrs) when is_map(attrs) do
    attempt_id = value(attrs, :attempt_id)

    case Attempts.get(attempt_id) do
      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt ->
        case command(attrs, attempt) do
          command when is_binary(command) -> {:ok, attempt, command}
          _missing -> {:error, :attempt_command_required}
        end
    end
  end

  defp command(attrs, attempt) do
    value(attrs, :command_kind) ||
      get_in(attempt.provenance || %{}, ["worker_pool", "command"]) ||
      command_for_purpose(get_in(attempt.provenance || %{}, ["purpose"]))
  end

  defp command_for_purpose("workspace_preparation"), do: "prepare_workspace"
  defp command_for_purpose("github_issue_implementation"), do: "implement"
  defp command_for_purpose("github_issue_verification"), do: "verify"
  defp command_for_purpose("github_issue_repair"), do: "repair"
  defp command_for_purpose("github_issue_publication"), do: "publish"
  defp command_for_purpose(_purpose), do: nil

  defp dispatch_state(%Attempt{state: state}) when state in ~w(queued running), do: :ok

  defp dispatch_state(%Attempt{state: "cancelled"} = attempt) do
    {:cancelled,
     refusal(:cancelled, "attempt_cancelled", "Attempt was cancelled before launch", %{
       attempt_id: attempt.attempt_id
     })}
  end

  defp dispatch_state(%Attempt{} = attempt) do
    {:blocked,
     refusal(:blocked, "attempt_terminal", "Attempt is already terminal", %{
       attempt_id: attempt.attempt_id,
       state: attempt.state
     })}
  end

  defp posture_policy(attempt) do
    policy = get_in(attempt.provenance || %{}, ["work_policy"])

    case WorkPolicy.posture(policy) do
      nil ->
        :ok

      :auto ->
        :ok

      :ask ->
        blocked_posture(attempt, "work_policy_gate_required", "Attempt policy requires a Gate")

      :ineligible ->
        blocked_posture(attempt, "work_policy_ineligible", "Attempt is ineligible under policy")

      :invalid ->
        blocked_posture(attempt, "work_policy_invalid", "Attempt policy is malformed")
    end
  end

  defp blocked_posture(attempt, code, message) do
    {:blocked,
     refusal(:blocked, code, message, %{
       attempt_id: attempt.attempt_id,
       work_policy: get_in(attempt.provenance || %{}, ["work_policy"])
     })}
  end

  defp select_worker(registry, requirements) do
    case AttemptWorkerRegistry.eligible(registry, requirements) do
      [worker | _rest] ->
        {:ok, worker}

      [] ->
        available =
          registry
          |> AttemptWorkerRegistry.list()
          |> Enum.map(& &1.name)

        {:blocked,
         refusal(
           :blocked,
           "no_eligible_worker",
           "No declared worker satisfies the Attempt requirements",
           %{requirements: requirements, available_workers: available}
         )}
    end
  end

  defp lease_policy(_attempt, %{isolation: "workspace_provisioning"}, _options), do: :ok

  defp lease_policy(attempt, %{isolation: "owned_worktree"}, options) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    case WorkspaceLeases.get_for_work_item(attempt.work_item.work_item_id) do
      %{state: "active"} = lease ->
        if DateTime.compare(lease.expires_at, now) == :gt do
          :ok
        else
          blocked_lease(attempt, lease, "workspace_lease_expired")
        end

      nil ->
        blocked_lease(attempt, nil, "workspace_lease_missing")

      lease ->
        blocked_lease(attempt, lease, "workspace_lease_not_active")
    end
  end

  defp blocked_lease(attempt, lease, code) do
    {:blocked,
     refusal(:blocked, code, "Owned workspace is unavailable for the Attempt", %{
       attempt_id: attempt.attempt_id,
       lease_id: lease && lease.lease_id,
       lease_state: lease && lease.state
     })}
  end

  defp spend_policy(attempt, body, options) do
    budget =
      get_in(attempt.provenance || %{}, ["work_policy", "controls", "budget"]) ||
        get_in(body, ["policy", "budget"]) ||
        %{}

    routine_id = get_in(attempt.provenance || %{}, ["legacy_routine_id"])
    usage = usage(routine_id, options)

    cond do
      reached?(usage.cost_usd, value(budget, :daily_budget_usd)) ->
        blocked_spend(
          attempt,
          "daily_budget_usd",
          usage.cost_usd,
          value(budget, :daily_budget_usd)
        )

      reached?(usage.tokens, value(budget, :daily_budget_tokens)) ->
        blocked_spend(
          attempt,
          "daily_budget_tokens",
          usage.tokens,
          value(budget, :daily_budget_tokens)
        )

      true ->
        {:ok, %{routine_id: routine_id, usage: usage, limits: normalize(budget)}}
    end
  end

  defp blocked_spend(attempt, rail, observed, limit) do
    {:blocked,
     refusal(:blocked, "spend_limit_reached", "Attempt spend policy refuses launch", %{
       attempt_id: attempt.attempt_id,
       rail: rail,
       observed: observed,
       limit: limit
     })}
  end

  defp usage(nil, _options), do: %{cost_usd: 0.0, tokens: 0}

  defp usage(routine_id, options) do
    case Keyword.get(options, :usage_fun) do
      nil ->
        %{
          cost_usd: SpendLedger.today(routine_id),
          tokens: SpendLedger.today_tokens(routine_id)
        }

      fun when is_function(fun, 1) ->
        fun.(routine_id)
    end
  end

  defp reached?(_observed, nil), do: false

  defp reached?(observed, limit) when is_number(observed) and is_number(limit),
    do: observed >= limit

  defp reached?(_observed, _limit), do: false

  defp concurrency_policy(attempt, worker, options) do
    active = active_count(attempt, worker, options)

    policy_limit =
      get_in(attempt.provenance || %{}, [
        "work_policy",
        "controls",
        "execution",
        "max_concurrency"
      ])

    limit =
      if is_integer(policy_limit) and policy_limit > 0,
        do: min(worker.max_concurrency, policy_limit),
        else: worker.max_concurrency

    if active < limit do
      {:ok, %{worker_limit: worker.max_concurrency, policy_limit: policy_limit, effective: limit}}
    else
      retry_after_ms = Keyword.get(options, :capacity_retry_after_ms, 5_000)
      details = %{worker: worker.name, active: active, limit: limit}

      details =
        if is_integer(policy_limit),
          do:
            Map.merge(details, %{
              worker_limit: worker.max_concurrency,
              policy_limit: policy_limit
            }),
          else: details

      {:retry,
       refusal(
         :retry,
         "concurrency_limit",
         "Eligible worker is at its concurrency limit",
         details,
         retry_after_ms
       )}
    end
  end

  defp active_count(attempt, worker, options) do
    case Keyword.get(options, :active_count_fun) do
      nil ->
        Repo.aggregate(
          from(other in Attempt,
            where:
              other.state == "running" and other.id != ^attempt.id and
                other.executor_kind in ^worker.executor_kinds and
                other.provider in ^worker.providers
          ),
          :count
        )

      fun when is_function(fun, 2) ->
        fun.(worker, attempt)
    end
  end

  defp cancel_delivery(%Attempt{oban_job_id: nil}, _options), do: :ok

  defp cancel_delivery(%Attempt{oban_job_id: job_id}, options) do
    cancel_fun = Keyword.get(options, :cancel_fun, &Oban.cancel_job/1)

    case cancel_fun.(job_id) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_proposal(attempt) do
    %{
      state: "blocked",
      phase: attempt.work_item.phase,
      blocked_reason: %{
        code: "attempt_cancelled",
        attempt_id: attempt.attempt_id
      },
      evidence: %{worker_pool: %{code: "attempt_cancelled"}}
    }
  end

  defp lost_reason(attempt, now) do
    lease = WorkspaceLeases.get_for_work_item(attempt.work_item.work_item_id)
    job = attempt.oban_job_id && Repo.get(Oban.Job, attempt.oban_job_id)
    command = command(%{}, attempt)

    case lost_lease_reason(lease, command, now) do
      nil -> lost_job_reason(job, attempt.oban_job_id)
      reason -> reason
    end
  end

  defp lost_lease_reason(nil, "prepare_workspace", _now), do: nil
  defp lost_lease_reason(nil, _command, _now), do: %{code: "workspace_lease_missing"}

  defp lost_lease_reason(%{state: state} = lease, _command, _now) when state != "active" do
    %{code: "workspace_lease_lost", lease_id: lease.lease_id, lease_state: state}
  end

  defp lost_lease_reason(lease, _command, now) do
    if DateTime.compare(lease.expires_at, now) == :gt,
      do: nil,
      else: %{code: "workspace_lease_expired", lease_id: lease.lease_id}
  end

  defp lost_job_reason(nil, job_id),
    do: %{code: "worker_delivery_missing", oban_job_id: job_id}

  defp lost_job_reason(job, _job_id) do
    if job.state in @live_job_states,
      do: nil,
      else: %{code: "worker_delivery_terminal", oban_job_id: job.id, job_state: job.state}
  end

  defp recover_lost(attempt, reason, _options) do
    refusal =
      refusal(
        :blocked,
        reason.code,
        "Attempt worker was lost before a durable outcome",
        Map.put(reason, :attempt_id, attempt.attempt_id)
      )

    outcome = %{
      kind: "worker_lost",
      worker_pool: Refusal.render(refusal),
      proposal: %{
        state: "blocked",
        phase: attempt.work_item.phase,
        blocked_reason: %{
          code: "worker_lost",
          attempt_id: attempt.attempt_id,
          worker_pool: Refusal.render(refusal)
        },
        evidence: %{worker_pool: Refusal.render(refusal)}
      }
    }

    with {:ok, finished} <-
           Attempts.finish(attempt.attempt_id, %{
             state: "failed",
             usage: attempt.usage,
             outcome: outcome,
             error_class: "worker_lost",
             error_details: Refusal.render(refusal)
           }),
         {:ok, transition} <- recover_work_item(finished, outcome.proposal) do
      {:ok,
       %{
         attempt_id: attempt.attempt_id,
         work_item_id: attempt.work_item.work_item_id,
         reason: Refusal.render(refusal),
         transition: transition
       }}
    end
  end

  defp recover_work_item(attempt, proposal) do
    work_item = WorkItems.get(attempt.work_item.work_item_id)

    if work_item.state == "active" and work_item.active_attempt_id == attempt.attempt_id do
      Transition.dispatch(
        work_item.work_item_id,
        Map.put(proposal, :expected_version, work_item.version),
        actor: %{kind: :system, id: "attempt-worker-pool"},
        transport: :worker,
        idempotency_key: "attempt-worker-pool:#{attempt.attempt_id}:lost"
      )
    else
      {:ok, %{status: :unchanged, work_item: work_item}}
    end
  end

  defp repository_id(attempt, body) do
    body
    |> value(:workspace_revision)
    |> value(:repository_id)
    |> case do
      repository_id when is_binary(repository_id) ->
        repository_id

      _missing ->
        attempt.work_item.work_item_id
        |> WorkItems.latest_source_snapshot()
        |> value(:repository_id)
    end
  end

  defp required_tools(capabilities) do
    case value(capabilities, :tools) do
      tools when is_list(tools) -> string_list(tools)
      tools when is_map(tools) -> string_list(value(tools, :allowed))
      _other -> []
    end
  end

  defp required_features(%Attempt{executor_kind: "model"}, capabilities) do
    case string_list(value(capabilities, :features)) do
      [] -> @model_features
      features -> features
    end
  end

  defp required_features(_attempt, capabilities),
    do: string_list(value(capabilities, :features))

  defp isolation("prepare_workspace"), do: "workspace_provisioning"
  defp isolation(_command), do: "owned_worktree"

  defp refusal(kind, code, message, details, retry_after_ms \\ nil) do
    %Refusal{
      kind: kind,
      code: code,
      message: message,
      details: normalize(details),
      retry_after_ms: retry_after_ms
    }
  end

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  defp atomize_top(map) when is_map(map) do
    Map.new(map, fn
      {key, item} when is_binary(key) -> {String.to_existing_atom(key), item}
      pair -> pair
    end)
  end

  defp atomize_top(_value), do: %{}

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize(%{__struct__: _} = struct), do: normalize(Map.from_struct(struct))

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, item} -> {to_string(key), normalize(item)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
end
