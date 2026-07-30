defmodule Custode.Executors.Claude do
  @moduledoc """
  Claude implementation of the provider-neutral `Custode.Executor` contract.

  Claude CLI argument names, `ObanClaude` response shapes, and
  `ClaudeWrapper` payloads stop at this module boundary.
  """

  @behaviour Custode.Executor

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.Result, as: ClaudeResult

  alias Custode.Executor.{
    Cancellation,
    Capabilities,
    Failure,
    Heartbeat,
    Request,
    Result,
    Version
  }

  alias Custode.GitHubIssueContext

  @adapter_version "1"
  @protocol_version "custode.executor.v1"
  @rail_stops ~w(budget_exceeded max_budget_exceeded max_turns_exceeded)a

  @impl Custode.Executor
  def capabilities do
    %Capabilities{
      provider: "claude",
      executor_kinds: ["model"],
      tools: GitHubIssueContext.allowed_tools(),
      operations: [],
      isolation: ["owned_worktree"],
      features: [
        "cancellation",
        "heartbeat",
        "provider_continuation",
        "structured_output",
        "timeout",
        "transcript_reference"
      ]
    }
  end

  @impl Custode.Executor
  def version do
    %Version{
      provider: "claude",
      adapter: "Custode.Executors.Claude",
      adapter_version: @adapter_version,
      runtime_version: package_version(:oban_claude),
      protocol_version: @protocol_version
    }
  end

  @impl Custode.Executor
  def execute(%Request{} = request, options) do
    args = provider_args(request)
    run_options = run_options(options)

    case ObanClaude.run(args, run_options) do
      {:ok, payload} ->
        {:ok, success(request, payload)}

      {{:error, reason}, payload} ->
        {:ok, failed(request, reason, payload)}

      {{:cancel, reason}, payload} ->
        {:ok, cancelled(request, reason, payload)}

      {verdict, payload} ->
        {:error,
         %Failure{
           classification: :contract_violation,
           message: "Claude returned an unsupported verdict",
           retryable: false,
           details: %{verdict: inspect(verdict), provider: provider_payload(payload)}
         }}
    end
  end

  @impl Custode.Executor
  def heartbeat(%Request{} = request, options) do
    case options[:heartbeat_fun] do
      fun when is_function(fun, 1) ->
        fun.(request)

      _default ->
        {:ok,
         %Heartbeat{
           attempt_id: request.attempt_id,
           status: :alive,
           observed_at: DateTime.utc_now(),
           details: %{
             provider: "claude",
             delivery_id: request.delivery["oban_job_id"]
           }
         }}
    end
  end

  @impl Custode.Executor
  def cancel(%Request{} = request, reason, options) do
    case options[:cancel_fun] do
      fun when is_function(fun, 2) ->
        fun.(request, reason)

      _default ->
        cancel_delivery(request, reason)
    end
  end

  defp success(request, %ClaudeResult{} = result) do
    session_id = ObanClaude.session_id(result)

    %Result{
      attempt_id: request.attempt_id,
      status: :succeeded,
      output: ObanClaude.structured(result),
      usage: usage(result),
      continuation: continuation(session_id),
      transcript_refs: transcript_refs(session_id),
      artifacts: [],
      cancellation: nil,
      failure: nil,
      evidence: provider_payload(result),
      executor: version_map()
    }
  end

  defp success(request, payload) do
    %Result{
      attempt_id: request.attempt_id,
      status: :succeeded,
      output: %{},
      usage: usage(payload),
      continuation: continuation(ObanClaude.session_id(payload)),
      transcript_refs: transcript_refs(ObanClaude.session_id(payload)),
      artifacts: [],
      cancellation: nil,
      failure: nil,
      evidence: provider_payload(payload),
      executor: version_map()
    }
  end

  defp failed(request, reason, payload) do
    classification = if reason == :timeout, do: :timeout, else: :infrastructure

    %Result{
      attempt_id: request.attempt_id,
      status: :failed,
      output: nil,
      usage: usage(payload),
      continuation: continuation(ObanClaude.session_id(payload)),
      transcript_refs: transcript_refs(ObanClaude.session_id(payload)),
      artifacts: [],
      cancellation: nil,
      failure: %Failure{
        classification: classification,
        message: "Claude execution failed",
        retryable: true,
        details: %{reason: reason}
      },
      evidence: provider_payload(payload),
      executor: version_map()
    }
  end

  defp cancelled(request, reason, payload) do
    classification = if reason in @rail_stops, do: :limit, else: :provider_refusal

    %Result{
      attempt_id: request.attempt_id,
      status: :cancelled,
      output: nil,
      usage: usage(payload),
      continuation: continuation(ObanClaude.session_id(payload)),
      transcript_refs: transcript_refs(ObanClaude.session_id(payload)),
      artifacts: [],
      cancellation: %{state: "cancelled", reason: inspect(reason)},
      failure: %Failure{
        classification: classification,
        message: "Claude execution was cancelled",
        retryable: false,
        details: %{reason: inspect(reason)}
      },
      evidence: provider_payload(payload),
      executor: version_map()
    }
  end

  defp provider_args(request) do
    request.selection
    |> Map.take(~w(model effort agent))
    |> Map.merge(limit_args(request.limits))
    |> maybe_put("hermetic", request.workspace["hermetic"])
    |> Map.merge(%{
      "working_dir" => request.workspace["path"],
      "permission_mode" => "accept_edits",
      "allowed_tools" => request.requirements["tools"] || [],
      "disallowed_tools" => request.requirements["disallowed_tools"] || [],
      "json_schema" => Jason.encode!(request.output_contract),
      "append_system_prompt" => request.instructions["system"],
      "prompt" => prompt(request)
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp limit_args(limits) do
    limits
    |> Map.take(~w(max_turns max_budget_usd))
    |> maybe_put("timeout", limits["timeout_ms"])
  end

  defp prompt(request) do
    """
    #{request.instructions["task"]}

    ContextBundle digest: #{request.context_bundle["digest"]}

    #{Jason.encode!(request.context_bundle["body"], pretty: true)}
    """
    |> String.trim()
  end

  defp run_options(options) do
    [job: options[:job]]
    |> maybe_put_option(:query_fun, options[:query_fun])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp usage(%ClaudeResult{} = result) do
    %{
      cost_usd: result.cost_usd,
      duration_ms: result.duration_ms,
      num_turns: result.num_turns,
      tokens: ClaudeWrapper.Result.usage(result),
      stop_reason: ClaudeWrapper.Result.stop_reason(result)
    }
  end

  defp usage(payload), do: %{cost_usd: ObanClaude.cost_usd(payload)}

  defp continuation(session_id) when is_binary(session_id), do: %{session_id: session_id}
  defp continuation(_missing), do: nil

  defp transcript_refs(session_id) when is_binary(session_id) do
    [%{kind: "provider_session", id: session_id}]
  end

  defp transcript_refs(_missing), do: []

  defp provider_payload(%ClaudeResult{} = result) do
    %{
      "kind" => "result",
      "result" => result.result,
      "is_error" => result.is_error,
      "session_id" => result.session_id,
      "cost_usd" => result.cost_usd,
      "duration_ms" => result.duration_ms,
      "num_turns" => result.num_turns,
      "usage" => ClaudeWrapper.Result.usage(result),
      "stop_reason" => ClaudeWrapper.Result.stop_reason(result),
      "structured_output" => ObanClaude.structured(result)
    }
  end

  defp provider_payload(%Error{} = error) do
    %{
      "kind" => "error",
      "error_kind" => to_string(error.kind),
      "message" => error.message,
      "reason" => inspect(error.reason),
      "session_id" => ObanClaude.session_id(error),
      "cost_usd" => ObanClaude.cost_usd(error)
    }
  end

  defp provider_payload(payload), do: %{"kind" => "other", "value" => inspect(payload)}

  defp cancel_delivery(request, reason) do
    case request.delivery["oban_job_id"] do
      job_id when is_integer(job_id) ->
        :ok = Oban.cancel_job(job_id)

        {:ok,
         %Cancellation{
           attempt_id: request.attempt_id,
           status: :requested,
           reason: reason,
           details: %{provider: "claude", delivery_id: job_id}
         }}

      _missing ->
        {:ok,
         %Cancellation{
           attempt_id: request.attempt_id,
           status: :unsupported,
           reason: reason,
           details: %{provider: "claude", reason: "delivery_id_missing"}
         }}
    end
  end

  defp version_map, do: version() |> Map.from_struct()

  defp package_version(application) do
    case Application.spec(application, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _unknown -> "unknown"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)
end
