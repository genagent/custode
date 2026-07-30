defmodule Custode.Test.ClaudeExecutorHarness do
  @moduledoc false

  alias Custode.Executor.{Cancellation, Request}

  def provider, do: "claude"
  def expected_usage, do: %{cost_usd: 0.25}

  def request do
    {:ok, request} =
      Request.new(%{
        attempt_id: "attempt-executor-conformance",
        work_item_id: "work-executor-conformance",
        mission_id: "mission-executor-conformance",
        context_bundle: %{
          id: "context-executor-conformance",
          digest: String.duplicate("a", 64),
          body: %{
            "objective" => "Exercise the neutral Executor contract",
            "acceptance" => %{"conformance" => true}
          }
        },
        role_binding: %{
          role_binding_id: "binding-executor-conformance",
          role_template_key: "profile:test",
          role_template_version: "1"
        },
        recipe: %{name: "bounded_implementation", version: "1"},
        requirements: %{
          executor_kind: "model",
          provider: "claude",
          tools: ["Read", "Edit"],
          disallowed_tools: ["Bash"],
          operations: [],
          isolation: ["owned_worktree"],
          features: ["cancellation", "heartbeat", "structured_output", "timeout"]
        },
        selection: %{model: "sonnet", effort: "low", profile: "test"},
        limits: %{max_turns: 2, max_budget_usd: 1.0, timeout_ms: 30_000},
        workspace: %{
          lease_id: "lease-executor-conformance",
          path: System.tmp_dir!(),
          isolation: "owned_worktree",
          hermetic: "project"
        },
        instructions: %{
          system: "Stay within the supplied bounded work.",
          task: "Implement only the supplied ContextBundle."
        },
        output_contract: %{
          type: "object",
          additionalProperties: false,
          required: ["outcome", "summary"],
          properties: %{
            outcome: %{type: "string"},
            summary: %{type: "string"}
          }
        },
        delivery: %{
          kind: "oban",
          oban_job_id: 12_345,
          delivery_attempt: 1,
          max_deliveries: 3
        }
      })

    request
  end

  def success_options(test_pid) do
    query_fun = fn _prompt, options ->
      send(test_pid, {:executor_provider_launched, options})

      {:ok,
       ObanClaude.Testing.structured_result(
         %{"outcome" => "success", "summary" => "contract satisfied"},
         cost_usd: 0.25,
         duration_ms: 50,
         num_turns: 1,
         session_id: "session-conformance"
       )}
    end

    [job: job(), query_fun: query_fun]
  end

  def cancelled_options do
    error =
      ObanClaude.Testing.error(:max_budget_exceeded,
        reason: %{session_id: "session-cancelled", cost_usd: 0.5}
      )

    [job: job(), query_fun: ObanClaude.Testing.fail(error)]
  end

  def crash_options do
    [job: job(), query_fun: fn _prompt, _options -> raise "provider crashed" end]
  end

  def timeout_options do
    [job: job(), query_fun: ObanClaude.Testing.fail(:timeout)]
  end

  def cancel_options do
    cancel_fun = fn request, reason ->
      {:ok,
       %Cancellation{
         attempt_id: request.attempt_id,
         status: :requested,
         reason: reason,
         details: %{delivery_id: request.delivery["oban_job_id"]}
       }}
    end

    [cancel_fun: cancel_fun]
  end

  defp job do
    %Oban.Job{
      id: 12_345,
      attempt: 1,
      max_attempts: 3,
      args: %{},
      meta: %{}
    }
  end
end

defmodule Custode.Test.CodexExecutorHarness do
  @moduledoc false

  alias Custode.Executor.{Cancellation, Request}

  def provider, do: "codex"

  def expected_usage do
    %{
      cost_usd: nil,
      num_turns: 1,
      tokens: %{"input_tokens" => 10, "output_tokens" => 4}
    }
  end

  def request do
    {:ok, request} =
      Request.new(%{
        attempt_id: "attempt-codex-executor-conformance",
        work_item_id: "work-codex-executor-conformance",
        mission_id: "mission-codex-executor-conformance",
        context_bundle: %{
          id: "context-codex-executor-conformance",
          digest: String.duplicate("b", 64),
          body: %{
            "objective" => "Exercise the neutral Executor contract with Codex",
            "acceptance" => %{"conformance" => true}
          }
        },
        role_binding: %{
          role_binding_id: "binding-codex-executor-conformance",
          role_template_key: "profile:test",
          role_template_version: "1"
        },
        recipe: %{name: "bounded_implementation", version: "1"},
        requirements: %{
          executor_kind: "model",
          provider: "codex",
          tools: ["Read", "Edit"],
          disallowed_tools: ["Bash"],
          operations: [],
          isolation: ["owned_worktree"],
          features: ["cancellation", "heartbeat", "structured_output", "timeout"]
        },
        selection: %{model: "gpt-5.6-codex", profile: nil},
        limits: %{max_turns: 1, max_budget_usd: 1.0, timeout_ms: 30_000},
        workspace: %{
          lease_id: "lease-codex-executor-conformance",
          path: System.tmp_dir!(),
          isolation: "owned_worktree",
          hermetic: "project"
        },
        instructions: %{
          system: "Stay within the supplied bounded work.",
          task: "Implement only the supplied ContextBundle."
        },
        output_contract: %{
          type: "object",
          additionalProperties: false,
          required: ["outcome", "summary"],
          properties: %{
            outcome: %{type: "string"},
            summary: %{type: "string"}
          }
        },
        delivery: %{
          kind: "oban",
          oban_job_id: 23_456,
          delivery_attempt: 1,
          max_deliveries: 3
        }
      })

    request
  end

  def success_options(test_pid) do
    query_fun = fn _prompt, options ->
      send(test_pid, {:executor_provider_launched, options})

      {:ok,
       ObanCodex.Testing.structured_result(
         %{"outcome" => "success", "summary" => "contract satisfied"},
         session_id: "session-conformance",
         usage: %{"input_tokens" => 10, "output_tokens" => 4}
       )}
    end

    [job: job(), query_fun: query_fun, output_schema_dir: output_schema_dir()]
  end

  def cancelled_options do
    error =
      ObanCodex.Testing.error(:policy_stop,
        reason: %{session_id: "session-cancelled", cost_usd: 0.5}
      )

    classifier = fn {:error, payload} -> {{:cancel, :budget_exceeded}, payload} end

    [
      job: job(),
      query_fun: ObanCodex.Testing.fail(error),
      classifier: classifier,
      output_schema_dir: output_schema_dir()
    ]
  end

  def crash_options do
    [
      job: job(),
      query_fun: fn _prompt, _options -> raise "provider crashed" end,
      output_schema_dir: output_schema_dir()
    ]
  end

  def timeout_options do
    [
      job: job(),
      query_fun: ObanCodex.Testing.fail(:timeout),
      output_schema_dir: output_schema_dir()
    ]
  end

  def cancel_options do
    cancel_fun = fn request, reason ->
      {:ok,
       %Cancellation{
         attempt_id: request.attempt_id,
         status: :requested,
         reason: reason,
         details: %{delivery_id: request.delivery["oban_job_id"]}
       }}
    end

    [cancel_fun: cancel_fun]
  end

  def output_schema_dir do
    Path.join(System.tmp_dir!(), "custode-codex-executor-tests")
  end

  defp job do
    %Oban.Job{
      id: 23_456,
      attempt: 1,
      max_attempts: 3,
      args: %{},
      meta: %{}
    }
  end
end

defmodule Custode.Executors.ClaudeConformanceTest do
  use ExUnit.Case, async: false

  alias Custode.Executor.Request
  alias Custode.Executors.Claude
  alias Custode.Test.ClaudeExecutorHarness

  use Custode.ExecutorConformance,
    adapter: Claude,
    harness: ClaudeExecutorHarness

  test "Claude CLI details are derived only inside the adapter" do
    request = ClaudeExecutorHarness.request()

    query_fun = fn prompt, options ->
      send(self(), {:claude_launch, prompt, options})

      {:ok,
       ObanClaude.Testing.structured_result(%{
         "outcome" => "success",
         "summary" => "translated"
       })}
    end

    assert {:ok, result} =
             Executor.execute(Claude, request,
               job: %Oban.Job{id: 12_345, attempt: 1, max_attempts: 3, meta: %{}},
               query_fun: query_fun
             )

    assert result.status == :succeeded
    assert_receive {:claude_launch, prompt, options}
    assert prompt =~ "ContextBundle digest: #{request.context_bundle["digest"]}"
    assert options[:permission_mode] == :accept_edits
    assert options[:allowed_tools] == ["Read", "Edit"]
    assert options[:disallowed_tools] == ["Bash"]
    assert options[:model] == "sonnet"
    assert options[:effort] == :low
    assert options[:timeout] == 30_000
  end

  test "request validation refuses missing or invalid execution limits" do
    attrs = ClaudeExecutorHarness.request() |> Map.from_struct()

    assert {:error, {:invalid_executor_limit, :timeout_ms}} =
             Request.new(put_in(attrs, [:limits, "timeout_ms"], 0))

    assert {:error, {:invalid_executor_limit, :max_turns}} =
             Request.new(put_in(attrs, [:limits, "max_turns"], nil))
  end

  test "request normalization preserves JSON booleans" do
    request = ClaudeExecutorHarness.request()

    assert request.context_bundle["body"]["acceptance"]["conformance"] == true
    assert request.output_contract["additionalProperties"] == false
  end
end

defmodule Custode.Executors.CodexConformanceTest do
  use ExUnit.Case, async: false

  alias Custode.Executor
  alias Custode.Executors.Codex
  alias Custode.Test.CodexExecutorHarness

  use Custode.ExecutorConformance,
    adapter: Codex,
    harness: CodexExecutorHarness

  setup do
    File.rm_rf!(CodexExecutorHarness.output_schema_dir())

    on_exit(fn ->
      File.rm_rf!(CodexExecutorHarness.output_schema_dir())
    end)

    :ok
  end

  test "Codex controls and structured schema are pinned inside the adapter" do
    request = CodexExecutorHarness.request()
    test_pid = self()

    query_fun = fn prompt, options ->
      send(test_pid, {:codex_launch, prompt, options})

      {:ok,
       ObanCodex.Testing.structured_result(%{
         "outcome" => "success",
         "summary" => "translated"
       })}
    end

    assert {:ok, result} =
             Executor.execute(Codex, request,
               job: %Oban.Job{id: 23_456, attempt: 1, max_attempts: 3, meta: %{}},
               query_fun: query_fun,
               output_schema_dir: CodexExecutorHarness.output_schema_dir()
             )

    assert result.status == :succeeded
    assert_receive {:codex_launch, prompt, options}
    assert prompt =~ "ContextBundle digest: #{request.context_bundle["digest"]}"
    assert options[:sandbox] == :workspace_write
    assert options[:approval_policy] == :never
    assert options[:search] == :disabled
    assert options[:ignore_user_config]
    assert options[:working_dir] == System.tmp_dir!()
    assert options[:model] == "gpt-5.6-codex"
    assert options[:timeout] == 30_000
    assert "sandbox_workspace_write.network_access=false" in options[:config_overrides]
    assert "mcp_servers={}" in options[:config_overrides]
    refute options[:dangerously_bypass_approvals_and_sandbox]

    assert request.output_contract ==
             options[:output_schema]
             |> File.read!()
             |> Jason.decode!()
  end
end
