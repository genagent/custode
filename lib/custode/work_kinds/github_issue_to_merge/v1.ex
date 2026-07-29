defmodule Custode.WorkKinds.GithubIssueToMerge.V1 do
  @moduledoc "Version 1 phase and decision contract for the design/008 repository vertical."

  @behaviour Custode.WorkKind

  alias Custode.WorkItem

  @phases ~w(
    discovered
    triaging
    ineligible
    eligible
    preparing_workspace
    compiling_context
    implementation_ready
    implementing
    verification_ready
    verifying
    repair_ready
    repairing
    publication_ready
    publishing
    awaiting_review
    feedback_ready
    handling_feedback
    conflict_ready
    resolving_conflict
    merge_ready
    merging
    landed
  )

  @state_phases %{
    "proposed" => ~w(discovered triaging ineligible),
    "ready" =>
      ~w(eligible implementation_ready verification_ready repair_ready publication_ready feedback_ready conflict_ready merge_ready),
    "active" =>
      ~w(preparing_workspace compiling_context implementing verifying repairing publishing handling_feedback resolving_conflict merging),
    "waiting" => @phases,
    "blocked" => @phases,
    "completed" => ~w(landed),
    "cancelled" => @phases
  }

  @phase_edges %{
    "discovered" => ~w(triaging),
    "triaging" => ~w(eligible ineligible),
    "ineligible" => ~w(triaging),
    "eligible" => ~w(ineligible preparing_workspace),
    "preparing_workspace" => ~w(compiling_context),
    "compiling_context" => ~w(implementation_ready),
    "implementation_ready" => ~w(implementing),
    "implementing" => ~w(verification_ready),
    "verification_ready" => ~w(verifying),
    "verifying" => ~w(publication_ready repair_ready),
    "repair_ready" => ~w(repairing),
    "repairing" => ~w(verification_ready),
    "publication_ready" => ~w(publishing),
    "publishing" => ~w(awaiting_review),
    "awaiting_review" => ~w(feedback_ready conflict_ready merge_ready),
    "feedback_ready" => ~w(handling_feedback),
    "handling_feedback" => ~w(verification_ready),
    "conflict_ready" => ~w(resolving_conflict),
    "resolving_conflict" => ~w(verification_ready),
    "merge_ready" => ~w(merging),
    "merging" => ~w(landed),
    "landed" => []
  }

  @evidence_requirements %{
    "triaging" => ~w(source_snapshot),
    "eligible" => ~w(eligibility),
    "implementation_ready" => ~w(context_bundle_digest),
    "verification_ready" => ~w(implementation),
    "publication_ready" => ~w(verification),
    "awaiting_review" => ~w(pull_request),
    "merge_ready" => ~w(merge_preconditions),
    "landed" => ~w(merge_commit acceptance)
  }

  @ready_commands %{
    "eligible" => %{
      action: :dispatch_attempt,
      kind: "prepare_workspace",
      phase: "preparing_workspace"
    },
    "implementation_ready" => %{
      action: :dispatch_attempt,
      kind: "implement",
      phase: "implementing"
    },
    "verification_ready" => %{action: :dispatch_attempt, kind: "verify", phase: "verifying"},
    "repair_ready" => %{action: :dispatch_attempt, kind: "repair", phase: "repairing"},
    "publication_ready" => %{action: :dispatch_attempt, kind: "publish", phase: "publishing"},
    "feedback_ready" => %{
      action: :dispatch_attempt,
      kind: "handle_feedback",
      phase: "handling_feedback"
    },
    "conflict_ready" => %{
      action: :dispatch_attempt,
      kind: "resolve_conflict",
      phase: "resolving_conflict"
    },
    "merge_ready" => %{action: :invoke_operation, operation: "github.merge_pr"}
  }

  @impl true
  def kind, do: "github_issue_to_merge"

  @impl true
  def version, do: 1

  @impl true
  def phases, do: @phases

  @impl true
  def validate_pair(state, phase) do
    cond do
      phase not in @phases ->
        {:error, {:unknown_phase, phase}}

      phase in Map.get(@state_phases, state, []) ->
        :ok

      true ->
        {:error, {:illegal_state_phase, %{state: state, phase: phase}}}
    end
  end

  @impl true
  def validate_transition(%WorkItem{} = work_item, target, evidence) do
    with :ok <- validate_pair(target.state, target.phase),
         :ok <- validate_phase_edge(work_item.phase, target.phase) do
      validate_evidence(work_item.phase, target.phase, evidence)
    end
  end

  @impl true
  def next_command(%WorkItem{state: "ready", phase: phase}, _world_snapshot) do
    case Map.fetch(@ready_commands, phase) do
      {:ok, command} -> {:ok, command}
      :error -> {:error, {:no_next_command, %{state: "ready", phase: phase}}}
    end
  end

  def next_command(%WorkItem{state: "waiting", waiting_condition: condition}, _world_snapshot),
    do: {:ok, %{action: :wait, condition: condition}}

  def next_command(%WorkItem{state: "blocked", blocked_reason: reason}, _world_snapshot),
    do: {:ok, %{action: :blocked, reason: reason}}

  def next_command(%WorkItem{state: "active"} = work_item, _world_snapshot) do
    {:ok,
     %{
       action: :observe,
       attempt_id: work_item.active_attempt_id,
       operation_call_id: work_item.active_operation_call_id
     }}
  end

  def next_command(%WorkItem{state: state}, _world_snapshot)
      when state in ["completed", "cancelled"],
      do: {:ok, %{action: :none, reason: :terminal}}

  def next_command(%WorkItem{state: "proposed", phase: "ineligible"}, _world_snapshot),
    do: {:ok, %{action: :none, reason: :ineligible}}

  def next_command(%WorkItem{state: "proposed"}, _world_snapshot),
    do: {:ok, %{action: :reconcile}}

  defp validate_phase_edge(phase, phase), do: :ok

  defp validate_phase_edge(from, to) do
    if to in Map.get(@phase_edges, from, []) do
      :ok
    else
      {:error, {:illegal_phase_transition, %{from: from, to: to}}}
    end
  end

  defp validate_evidence(phase, phase, _evidence), do: :ok

  defp validate_evidence(_from, to, evidence) when is_map(evidence) do
    missing =
      @evidence_requirements
      |> Map.get(to, [])
      |> Enum.reject(&Map.has_key?(evidence, &1))

    if missing == [], do: :ok, else: {:error, {:missing_evidence, missing}}
  end

  defp validate_evidence(_from, to, _evidence) do
    case Map.get(@evidence_requirements, to, []) do
      [] -> :ok
      missing -> {:error, {:missing_evidence, missing}}
    end
  end
end
