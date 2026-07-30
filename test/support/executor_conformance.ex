defmodule Custode.ExecutorConformance do
  @moduledoc """
  Shared conformance cases for production Executor adapters.

  A harness supplies one valid request and provider-specific test options.
  Codex and later adapters can run the same cases without copying assertions.
  """

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)
    harness = options |> Keyword.fetch!(:harness) |> Macro.expand(__CALLER__)

    quote do
      alias Custode.Executor
      alias Custode.Executor.{Cancellation, Failure, Heartbeat, Result, Version}

      @executor_adapter unquote(adapter)
      @executor_harness unquote(harness)

      unquote(discovery_and_success_tests())
      unquote(refusal_and_control_tests())
    end
  end

  defp discovery_and_success_tests do
    quote do
      test "reports neutral capabilities and version metadata" do
        assert {:ok, capabilities} = Executor.capabilities(@executor_adapter)
        assert capabilities.provider == @executor_harness.provider()
        assert capabilities.executor_kinds != []
        assert "heartbeat" in capabilities.features
        assert "cancellation" in capabilities.features
        assert "timeout" in capabilities.features

        assert {:ok, %Version{} = version} = Executor.version(@executor_adapter)
        assert version.provider == capabilities.provider
        assert version.adapter_version != ""
        assert version.protocol_version == "custode.executor.v1"

        refute Map.has_key?(Map.from_struct(capabilities), :session_state)
        refute Map.has_key?(Map.from_struct(capabilities), :provider_lifecycle)
      end

      test "returns typed success, usage, transcript references, and provider evidence" do
        request = @executor_harness.request()

        assert {:ok, %Result{} = result} =
                 Executor.execute(
                   @executor_adapter,
                   request,
                   @executor_harness.success_options(self())
                 )

        assert_receive {:executor_provider_launched, provider_options}
        assert result.attempt_id == request.attempt_id
        assert result.status == :succeeded
        assert result.output["outcome"] == "success"
        assert result.usage.cost_usd == 0.25

        assert [%{kind: "provider_session", id: "session-conformance"}] =
                 result.transcript_refs

        assert result.failure == nil
        assert result.evidence["kind"] == "result"
        assert result.evidence["structured_output"] == result.output
        assert result.executor.provider == @executor_harness.provider()
        assert is_list(result.artifacts)
        assert is_list(provider_options)
      end
    end
  end

  defp refusal_and_control_tests do
    quote do
      test "rejects capability mismatch before provider launch" do
        request = @executor_harness.request()

        mismatch = %{
          request
          | requirements: Map.update!(request.requirements, "tools", &["unsupported_tool" | &1])
        }

        assert {:ok,
                %Result{
                  attempt_id: attempt_id,
                  status: :rejected,
                  failure: %Failure{
                    classification: :capability_mismatch,
                    retryable: false
                  }
                }} =
                 Executor.execute(
                   @executor_adapter,
                   mismatch,
                   @executor_harness.success_options(self())
                 )

        assert attempt_id == request.attempt_id
        refute_receive {:executor_provider_launched, _options}
      end

      test "normalizes provider cancellation and preserves one Attempt identity" do
        request = @executor_harness.request()

        assert {:ok,
                %Result{
                  attempt_id: attempt_id,
                  status: :cancelled,
                  cancellation: %{},
                  failure: %Failure{classification: :limit, retryable: false}
                }} =
                 Executor.execute(
                   @executor_adapter,
                   request,
                   @executor_harness.cancelled_options()
                 )

        assert attempt_id == request.attempt_id

        assert {:ok, %Cancellation{attempt_id: ^attempt_id, status: :requested}} =
                 Executor.cancel(
                   @executor_adapter,
                   request,
                   :operator_cancelled,
                   @executor_harness.cancel_options()
                 )
      end

      test "adapter crashes become retryable typed failures on the same Attempt" do
        request = @executor_harness.request()

        assert {:ok,
                %Result{
                  attempt_id: attempt_id,
                  status: :failed,
                  failure: %Failure{
                    classification: :provider_crash,
                    retryable: true
                  }
                }} =
                 Executor.execute(
                   @executor_adapter,
                   request,
                   @executor_harness.crash_options()
                 )

        assert attempt_id == request.attempt_id
      end

      test "timeouts are typed and preserve one Attempt identity" do
        request = @executor_harness.request()

        assert {:ok,
                %Result{
                  attempt_id: attempt_id,
                  status: :failed,
                  failure: %Failure{
                    classification: :timeout,
                    retryable: true
                  }
                }} =
                 Executor.execute(
                   @executor_adapter,
                   request,
                   @executor_harness.timeout_options()
                 )

        assert attempt_id == request.attempt_id
      end

      test "heartbeat observations remain tied to the logical Attempt" do
        request = @executor_harness.request()

        assert {:ok, %Heartbeat{attempt_id: attempt_id, status: :alive}} =
                 Executor.heartbeat(@executor_adapter, request)

        assert attempt_id == request.attempt_id
      end
    end
  end
end
