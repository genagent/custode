defmodule Custode.Executors.Codex do
  @moduledoc """
  Codex implementation of the provider-neutral `Custode.Executor` contract.

  Codex CLI arguments, `ObanCodex` verdicts, and `CodexWrapper` payloads stop
  at this module boundary. The host owns the worktree lease and pins Codex to
  workspace writes without network, MCP servers, or interactive approvals.
  """

  @behaviour Custode.Executor

  alias CodexWrapper.Result, as: CodexResult
  alias ObanCodex.Error

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
  @pinned_config [
    "sandbox_workspace_write.network_access=false",
    "mcp_servers={}",
    "features.multi_agent_v2=false",
    "tools.web_search=false"
  ]

  @impl Custode.Executor
  def capabilities do
    %Capabilities{
      provider: "codex",
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
      provider: "codex",
      adapter: "Custode.Executors.Codex",
      adapter_version: @adapter_version,
      runtime_version: package_version(:oban_codex),
      protocol_version: @protocol_version
    }
  end

  @impl Custode.Executor
  def execute(%Request{} = request, options) do
    case write_output_schema(request, options) do
      {:ok, schema_path} ->
        request
        |> provider_args(schema_path)
        |> ObanCodex.run(run_options(options))
        |> normalize_verdict(request)

      {:error, reason} ->
        {:error,
         %Failure{
           classification: :infrastructure,
           message: "Codex output contract could not be prepared",
           retryable: true,
           details: %{reason: inspect(reason)}
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
             provider: "codex",
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

  defp normalize_verdict({:ok, payload}, request), do: {:ok, success(request, payload)}

  defp normalize_verdict({{:ok, _value}, payload}, request),
    do: {:ok, success(request, payload)}

  defp normalize_verdict({{:error, reason}, payload}, request),
    do: {:ok, failed(request, reason, payload)}

  defp normalize_verdict({{:cancel, reason}, payload}, request),
    do: {:ok, cancelled(request, reason, payload)}

  defp normalize_verdict({verdict, payload}, _request) do
    {:error,
     %Failure{
       classification: :contract_violation,
       message: "Codex returned an unsupported verdict",
       retryable: false,
       details: %{verdict: inspect(verdict), provider: provider_payload(payload)}
     }}
  end

  defp success(request, %CodexResult{} = result) do
    session_id = ObanCodex.session_id(result)

    %Result{
      attempt_id: request.attempt_id,
      status: :succeeded,
      output: structured_output(result),
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
      continuation: continuation(ObanCodex.session_id(payload)),
      transcript_refs: transcript_refs(ObanCodex.session_id(payload)),
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
      continuation: continuation(ObanCodex.session_id(payload)),
      transcript_refs: transcript_refs(ObanCodex.session_id(payload)),
      artifacts: [],
      cancellation: nil,
      failure: %Failure{
        classification: classification,
        message: "Codex execution failed",
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
      continuation: continuation(ObanCodex.session_id(payload)),
      transcript_refs: transcript_refs(ObanCodex.session_id(payload)),
      artifacts: [],
      cancellation: %{state: "cancelled", reason: inspect(reason)},
      failure: %Failure{
        classification: classification,
        message: "Codex execution was cancelled",
        retryable: false,
        details: %{reason: inspect(reason)}
      },
      evidence: provider_payload(payload),
      executor: version_map()
    }
  end

  defp provider_args(request, schema_path) do
    request.selection
    |> Map.take(~w(model profile))
    |> Map.merge(%{
      "working_dir" => request.workspace["path"],
      "sandbox" => "workspace_write",
      "approval_policy" => "never",
      "search" => "disabled",
      "ignore_user_config" => true,
      "config_overrides" => @pinned_config,
      "output_schema" => schema_path,
      "timeout" => request.limits["timeout_ms"],
      "prompt" => prompt(request)
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp prompt(request) do
    """
    #{request.instructions["system"]}

    #{request.instructions["task"]}

    ContextBundle digest: #{request.context_bundle["digest"]}

    #{Jason.encode!(request.context_bundle["body"], pretty: true)}
    """
    |> String.trim()
  end

  defp run_options(options) do
    [job: options[:job]]
    |> maybe_put_option(:query_fun, options[:query_fun])
    |> maybe_put_option(:classifier, options[:classifier])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp write_output_schema(request, options) do
    encoded = Jason.encode!(request.output_contract)
    digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)

    directory =
      options[:output_schema_dir] ||
        Custode.Home.resolve_in(&Custode.Home.data_dir/0, "executor_schemas")

    path = Path.join(directory, "#{digest}.json")

    with :ok <- File.mkdir_p(directory),
         :ok <- write_once(path, encoded) do
      {:ok, path}
    end
  end

  defp write_once(path, encoded) do
    case File.read(path) do
      {:ok, ^encoded} -> :ok
      {:ok, _other} -> {:error, {:output_schema_conflict, path}}
      {:error, :enoent} -> write_exclusive(path, encoded)
      {:error, reason} -> {:error, {:output_schema_read_failed, reason}}
    end
  end

  defp write_exclusive(path, encoded) do
    case File.write(path, encoded, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> write_once(path, encoded)
      {:error, reason} -> {:error, {:output_schema_write_failed, reason}}
    end
  end

  defp structured_output(result) do
    case ObanCodex.structured(result) do
      output when is_map(output) -> output
      _other -> %{}
    end
  end

  defp usage(%CodexResult{} = result) do
    tokens = ObanCodex.usage(result)

    %{
      cost_usd: nil,
      duration_ms: nil,
      num_turns: completed_turns(result),
      tokens: tokens,
      stop_reason: nil
    }
  end

  defp usage(payload), do: %{cost_usd: ObanCodex.cost_usd(payload)}

  defp completed_turns(result) do
    result
    |> ObanCodex.events()
    |> Enum.count(&(&1.event_type == "turn.completed"))
  end

  defp continuation(session_id) when is_binary(session_id), do: %{session_id: session_id}
  defp continuation(_missing), do: nil

  defp transcript_refs(session_id) when is_binary(session_id) do
    [%{kind: "provider_session", id: session_id}]
  end

  defp transcript_refs(_missing), do: []

  defp provider_payload(%CodexResult{} = result) do
    %{
      "kind" => "result",
      "success" => result.success,
      "exit_code" => result.exit_code,
      "stdout" => result.stdout,
      "stderr" => result.stderr,
      "session_id" => ObanCodex.session_id(result),
      "cost_usd" => nil,
      "usage" => ObanCodex.usage(result),
      "structured_output" => structured_output(result)
    }
  end

  defp provider_payload(%Error{} = error) do
    %{
      "kind" => "error",
      "error_kind" => to_string(error.kind),
      "message" => error.message,
      "reason" => inspect(error.reason),
      "session_id" => ObanCodex.session_id(error),
      "cost_usd" => ObanCodex.cost_usd(error)
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
           details: %{provider: "codex", delivery_id: job_id}
         }}

      _missing ->
        {:ok,
         %Cancellation{
           attempt_id: request.attempt_id,
           status: :unsupported,
           reason: reason,
           details: %{provider: "codex", reason: "delivery_id_missing"}
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

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)
end
