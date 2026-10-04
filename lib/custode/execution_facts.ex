defmodule Custode.ExecutionFacts do
  @moduledoc """
  Truthful execution facts shared by operator surfaces.

  A routine describes the next desired execution. A live provider process
  describes the contract it actually has applied, and provider jobs preserve
  the arguments captured for individual turns. Those sources are kept
  separate so a roster edit cannot relabel a live or historical turn.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Agents, Repo, Routine}

  @turn_workers ["ObanClaude.Agent.Job", "ObanCodex.Agent.Job"]
  @continuation_states [:running, :waiting_for_user, :awaiting_permission]
  @active_job_states ~w(available scheduled executing retryable suspended)

  @type execution :: %{
          provider: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          working_dir: String.t() | nil,
          config_revision: String.t() | nil
        }

  @doc "Read desired, applied, active-turn, and captured-turn execution facts."
  def read(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    routine = read_source(opts, :routine, fn -> Routine.get(agent_id) end)

    # Provider agents publish a continuation only after its Oban job is
    # inserted. Snapshotting the process first therefore makes the following
    # query include the job named by that continuation. Reading in the reverse
    # order can report a running process with no active turn.
    process = read_source(opts, :process, fn -> live_process(agent_id) end)
    turns = read_source(opts, :turns, fn -> captured_turns(agent_id) end)

    project(desired_execution(routine), process, turns)
  end

  @doc false
  def project(desired, {:error, reason}, turns) when is_list(turns) do
    %{
      active: nil,
      applied: nil,
      desired: desired,
      turns: turns,
      live_error: reason
    }
  end

  def project(desired, process, turns)
      when (is_map(process) or is_nil(process)) and is_list(turns) do
    correlated = correlate_turn(turns, process)
    active = active_turn(correlated, process)

    %{
      active: active,
      applied: applied_execution(process, desired),
      desired: desired,
      turns: turns,
      live_error: nil
    }
  end

  defp desired_execution(nil), do: nil

  defp desired_execution(routine) do
    %{
      provider: routine.provider |> to_string(),
      model: routine.model,
      effort: stringify(routine.effort),
      working_dir: Path.expand(routine.working_dir),
      config_revision: Routine.execution_revision(routine)
    }
  end

  defp live_process(agent_id) do
    case Agents.live_provider(agent_id) do
      {:ok, provider} -> read_live_process(agent_id, provider)
      :offline -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_live_process(agent_id, provider) do
    case Agents.info(agent_id, provider) do
      {:ok, info} ->
        %{
          provider: to_string(provider),
          state: normalize_state(value(info, :state)),
          config_revision: value(info, :config_revision),
          continuation: value(info, :continuation)
        }

      {:error, :agent_not_running} ->
        nil

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp applied_execution(nil, _desired), do: nil

  defp applied_execution(process, desired) do
    inferred = if exact_contract?(process, desired), do: desired, else: %{}

    %{
      provider: process.provider,
      model: Map.get(inferred, :model),
      effort: Map.get(inferred, :effort),
      working_dir: Map.get(inferred, :working_dir),
      config_revision: process.config_revision,
      state: stringify(process.state),
      generation: continuation_value(process, :agent_generation),
      turn_id: continuation_value(process, :agent_turn_id)
    }
  end

  defp exact_contract?(process, desired) when is_map(desired) do
    is_binary(process.config_revision) and process.config_revision != "" and
      process.provider == desired.provider and
      process.config_revision == desired.config_revision
  end

  defp exact_contract?(_process, _desired), do: false

  defp correlate_turn(_turns, nil), do: nil

  defp correlate_turn(turns, process) do
    generation = continuation_value(process, :agent_generation)
    turn_id = continuation_value(process, :agent_turn_id)

    if durable_identity?(generation) and durable_identity?(turn_id) do
      Enum.find(turns, fn turn ->
        turn.provider == process.provider and turn.generation == generation and
          turn.turn_id == turn_id
      end)
    end
  end

  defp active_turn(nil, _process), do: nil

  defp active_turn(turn, process) do
    if continuation_relevant?(turn, process), do: apply_process_truth(turn, process)
  end

  defp continuation_relevant?(_turn, %{state: state}) when state in @continuation_states, do: true

  defp continuation_relevant?(turn, %{state: :paused}),
    do: stringify(turn.state) in @active_job_states

  defp continuation_relevant?(_turn, _process), do: false

  defp apply_process_truth(turn, process) do
    turn
    |> Map.put(:lifecycle_state, stringify(process.state))
    |> Map.put(:process_revision, process.config_revision)
    |> Map.put(:provider_session_id, observed_session(turn, process))
    |> Map.put(
      :revision_mismatch,
      revision_mismatch?(turn.config_revision, process.config_revision)
    )
  end

  defp observed_session(turn, process) do
    expected = [
      {:id, :job_id},
      {:attempt, :job_attempt},
      {:snoozed, :job_snoozed},
      {:arc_id, :arc_id}
    ]

    matched? =
      Enum.all?(expected, fn {captured_key, live_key} ->
        captured = Map.get(turn, captured_key)
        not is_nil(captured) and captured == continuation_value(process, live_key)
      end)

    session_id = continuation_value(process, :session_id)
    if matched? and durable_identity?(session_id), do: session_id
  end

  defp captured_turns(agent_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker in ^@turn_workers,
        where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^agent_id,
        order_by: [desc: j.id],
        limit: 40
      )
    )
    |> Enum.map(&captured_turn/1)
  end

  defp captured_turn(%Oban.Job{} = job) do
    %{
      id: job.id,
      attempt: job.attempt,
      snoozed: job.meta["snoozed"] || 0,
      arc_id: job.meta["arc_id"],
      state: job.state,
      provider: provider_for(job.worker),
      model: job.args["model"],
      effort: captured_effort(job.args),
      working_dir: job.args["working_dir"],
      config_revision: job.meta["config_revision"],
      generation: job.meta["agent_generation"],
      turn_id: job.meta["agent_turn_id"]
    }
  end

  defp provider_for("ObanClaude.Agent.Job"), do: "claude"
  defp provider_for("ObanCodex.Agent.Job"), do: "codex"

  defp captured_effort(%{"effort" => effort}) when is_binary(effort), do: effort

  defp captured_effort(%{"config_overrides" => overrides}) when is_list(overrides) do
    Enum.find_value(overrides, fn
      override when is_binary(override) ->
        case Regex.run(~r/^model_reasoning_effort="([^"]+)"$/, override) do
          [_, effort] -> effort
          _other -> nil
        end

      _other ->
        nil
    end)
  end

  defp captured_effort(_args), do: nil

  defp read_source(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, reader} when is_function(reader, 0) -> reader.()
      {:ok, value} -> value
      :error -> default.()
    end
  end

  defp continuation_value(%{continuation: continuation}, key) when is_map(continuation),
    do: value(continuation, key)

  defp continuation_value(_process, _key), do: nil

  defp normalize_state({state, _detail}) when is_atom(state), do: state
  defp normalize_state(state) when is_atom(state), do: state
  defp normalize_state(state) when is_binary(state), do: state
  defp normalize_state(_unknown), do: nil

  defp durable_identity?(value), do: is_binary(value) and value != ""

  defp revision_mismatch?(captured, process)
       when is_binary(captured) and captured != "" and is_binary(process) and process != "",
       do: captured != process

  defp revision_mismatch?(_captured, _process), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
end
