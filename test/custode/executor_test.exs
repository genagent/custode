defmodule Custode.Test.ClaudeExecutorHarness do
  @moduledoc false

  alias Custode.Executor.{Cancellation, Request}

  def provider, do: "claude"

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
end
