defmodule CustodeGenAgentProof.ProvidersTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.{Claude, Codex}

  defmodule Runner do
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("fixture permits streaming only")

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      provider = if binary == "/fixture/claude", do: :claude, else: :codex
      send(self(), {:launch, provider, args, opts, timeout})
      prompt = List.last(args)
      frames(provider, prompt) |> Enum.map(&Jason.encode!/1)
    end

    defp frames(:claude, "fail") do
      [
        %{"type" => "system", "subtype" => "init", "session_id" => "claude-fixture"},
        %{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "session_id" => "claude-fixture",
          "errors" => ["fixture failure"]
        }
      ]
    end

    defp frames(:claude, _prompt) do
      [
        %{"type" => "system", "subtype" => "init", "session_id" => "claude-fixture"},
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "session_id" => "claude-fixture",
          "result" => "fixture answer",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
        }
      ]
    end

    defp frames(:codex, "fail") do
      [
        %{"type" => "thread.started", "thread_id" => "codex-fixture"},
        %{"type" => "turn.failed", "error" => %{"message" => "fixture failure"}}
      ]
    end

    defp frames(:codex, prompt) do
      total = if prompt == "next", do: 60, else: 50

      [
        %{"type" => "thread.started", "thread_id" => "codex-fixture"},
        %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "commentary"}
        },
        %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "{\"ok\":true}"}
        },
        %{"type" => "turn.completed", "usage" => %{"input_tokens" => total, "output_tokens" => 5}}
      ]
    end
  end

  setup do
    for app <- [:claude_wrapper, :codex_wrapper] do
      previous = Application.fetch_env(app, :runner)
      Application.put_env(app, :runner, Runner)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(app, :runner, value)
          :error -> Application.delete_env(app, :runner)
        end
      end)
    end

    :ok
  end

  test "default Claude backend reaches the released wrapper and preserves captured policy on resume" do
    options = [
      binary: "/fixture/claude",
      working_dir: System.tmp_dir!(),
      timeout: 500,
      model: "fixture-model",
      effort: :low,
      tools: [""],
      allowed_tools: ["Read"],
      max_turns: 1,
      max_budget_usd: 0.1,
      permission_mode: :dont_ask,
      json_schema: "{\"type\":\"object\"}"
    ]

    {:ok, session} = Claude.start_session(options)
    {events, session} = consume(Claude, session, "first")
    assert_receive {:launch, :claude, initial, opts, nil}
    assert opts[:cd] == System.tmp_dir!()
    # Released Claude streaming discards Config.timeout. This is a host blocker,
    # not proof of a 500ms runner deadline. The one-shot path is separate.
    assert session.opts[:timeout] == 500
    refute "--resume" in initial
    assert_claude_policy(initial)
    assert Enum.any?(events, &(&1.kind == :usage))
    assert Enum.find(events, &(&1.kind == :result)).data.text == "fixture answer"

    {:ok, restored} = Claude.resume_session(session.session_id, options)
    consume(Claude, restored, "second")
    assert_receive {:launch, :claude, resumed, _, nil}
    assert pair?(resumed, "--resume", "claude-fixture")
    assert_claude_policy(resumed)
  end

  test "Claude default stream exposes an early checkpoint before provider failure" do
    {:ok, session} = Claude.start_session(binary: "/fixture/claude")
    {events, _} = consume(Claude, session, "fail")
    assert_receive {:launch, :claude, _, _, _}
    assert next_message() == {:checkpoint, "claude-fixture"}
    assert_receive {:normalized, :error}
    assert List.last(events).kind == :error
    assert Claude.checkpoint_session(session, "claude-fixture").session_id == "claude-fixture"
  end

  test "Codex default fresh and resumed launches retain policy while restored usage stays unknown" do
    options = [
      binary: "/fixture/codex",
      working_dir: System.tmp_dir!(),
      timeout: 500,
      model: "fixture-model",
      sandbox: :read_only,
      approval_policy: :never,
      ignore_user_config: true,
      config_overrides: ["model_reasoning_effort=\"low\""],
      output_schema: "/fixture/schema.json",
      response_text: :final_message
    ]

    {:ok, session} = Codex.start_session(options)
    {events, session} = consume(Codex, session, "first")
    assert_receive {:launch, :codex, fresh, opts, 500}
    assert opts[:cd] == System.tmp_dir!()
    assert pair?(fresh, "--sandbox", "read-only")
    assert_codex_policy(fresh)
    assert Enum.find(events, &(&1.kind == :usage)).data.input_tokens == 50
    assert Enum.find(events, &(&1.kind == :result)).data.text == "{\"ok\":true}"

    {:ok, restored} = Codex.resume_session(session.thread_id, options)
    assert restored.usage_total == %{}
    {events, restored} = consume(Codex, restored, "restored")
    assert_receive {:launch, :codex, resumed, _, 500}
    assert "resume" in resumed
    assert "codex-fixture" in resumed
    assert "sandbox_mode=\"read-only\"" in resumed
    assert "approval_policy=\"never\"" in resumed
    assert_codex_policy(resumed)
    refute Enum.any?(events, &(&1.kind == :usage))

    {events, _} = consume(Codex, restored, "next")
    assert Enum.find(events, &(&1.kind == :usage)).data.input_tokens == 10
  end

  test "Codex default stream exposes an early checkpoint before provider failure" do
    {:ok, session} = Codex.start_session(binary: "/fixture/codex")
    {events, _} = consume(Codex, session, "fail")
    assert_receive {:launch, :codex, _, _, _}
    assert next_message() == {:checkpoint, "codex-fixture"}
    assert_receive {:normalized, :error}
    assert List.last(events).kind == :error
    refute Enum.any?(events, &(&1.kind == :usage))
  end

  test "optional cleanup runners compile with Custode's released Forcola" do
    for runner <- [ClaudeWrapper.Runner.Forcola, CodexWrapper.Runner.Forcola] do
      assert Code.ensure_loaded?(runner)
      assert function_exported?(runner, :run, 4)
      assert function_exported?(runner, :stream_lines, 4)
    end
  end

  test "unsupported continuation and cap options are refused without a runner call" do
    assert {:error, {:unsupported_option, :no_session_persistence}} =
             Claude.start_session(no_session_persistence: true)

    for opts <- [[search: true], [ephemeral: true], [system_prompt: "policy"], [max_tokens: 100]] do
      assert {:error, _} = Codex.start_session(opts)
    end

    refute_receive {:launch, _, _, _, _}
  end

  defp consume(backend, session, prompt) do
    owner = self()

    checkpoint = fn id ->
      send(owner, {:checkpoint, id})
      :ok
    end

    {:ok, stream, session} = backend.prompt(session, prompt, %{checkpoint: checkpoint})
    events = stream |> Stream.each(&send(owner, {:normalized, &1.kind})) |> Enum.to_list()
    result = Enum.find(events, &(&1.kind == :result))
    session = if result, do: backend.update_session(session, result.data), else: session
    {events, session}
  end

  defp next_message do
    receive do
      message -> message
    after
      100 -> flunk("expected ordered fixture observation")
    end
  end

  defp assert_claude_policy(args) do
    assert pair?(args, "--model", "fixture-model")
    assert pair?(args, "--effort", "low")
    assert pair?(args, "--tools", "")
    assert pair?(args, "--allowed-tools", "Read")
    assert pair?(args, "--max-turns", "1")
    assert pair?(args, "--max-budget-usd", "0.1")
    assert pair?(args, "--permission-mode", "dontAsk")
    assert pair?(args, "--json-schema", "{\"type\":\"object\"}")
  end

  defp assert_codex_policy(args) do
    assert pair?(args, "--model", "fixture-model")
    assert pair?(args, "--output-schema", "/fixture/schema.json")
    assert "model_reasoning_effort=\"low\"" in args
    assert "--ignore-user-config" in args
  end

  defp pair?(args, key, value),
    do: Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?([key, value])
end
