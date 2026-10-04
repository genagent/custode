defmodule Custode.Assurance.NativeEventsTest do
  use ExUnit.Case, async: true
  alias Custode.Assurance.Native.Events

  @opinion %{"verdict" => "accept", "findings" => [], "check_exit_code" => 0}

  test "Claude native identity and successful result retain authored opinion separately" do
    raw = stream([claude_init(), claude_result()])
    observed = Events.observe("claude", raw)

    assert observed["session_id"] == "claude-session"
    assert observed["observed_model"] == "claude-sonnet-fixture"
    assert observed["terminal_observed"]
    assert observed["usage"] == %{"input_tokens" => 12, "output_tokens" => 7}
    assert observed["cost_usd"] == 0.01
    assert observed["commands"] == []
    assert observed["opinion"] == @opinion
    assert observed["malformed_lines"] == 0
    assert observed["protocol_errors"] == []
    assert observed["stream_sha256"] == digest(raw)
  end

  test "Codex native command receipts remain distinct from authored verdict and claimed exits" do
    opinion = %{"verdict" => "accept", "findings" => [], "check_exit_code" => 0}
    command = codex_command(%{"exit_code" => 1, "aggregated_output" => "pinned check failed\n"})
    raw = stream([codex_init(), command, codex_opinion(opinion), codex_terminal()])
    observed = Events.observe("codex", raw)

    assert observed["session_id"] == "codex-thread"
    assert observed["observed_model"] == nil
    assert observed["terminal_observed"]
    assert observed["usage"] == %{"input_tokens" => 20, "output_tokens" => 10}
    assert observed["cost_usd"] == nil
    assert observed["opinion"] == opinion
    assert observed["commands"] == [Map.drop(command["item"], ["type"])]
    assert observed["commands"] |> hd() |> Map.fetch!("exit_code") == 1
    assert observed["protocol_errors"] == []
    assert observed["stream_sha256"] == digest(raw)
  end

  test "malformed, non-object and missing or non-string type lines never become valid evidence" do
    invalid_lines = ["{", "null", "[]", "42", "\"authored prose\"", "{}", "{\"type\":7}"]

    for provider <- ~w(claude codex), invalid <- invalid_lines do
      {initial, terminal} = boundary(provider)
      raw = Jason.encode!(initial) <> "\n" <> invalid <> "\n" <> Jason.encode!(terminal)
      observed = Events.observe(provider, raw)

      assert observed["malformed_lines"] == 1, "#{provider}: #{invalid}"
      assert "non_object_or_malformed_native_line" in observed["protocol_errors"]
      assert observed["stream_sha256"] == digest(raw)
    end
  end

  test "missing identity or terminal is explicit rather than inferred from an authored opinion" do
    for provider <- ~w(claude codex) do
      {initial, terminal} = boundary(provider)
      missing_identity = Events.observe(provider, stream([terminal]))
      missing_terminal = Events.observe(provider, stream([initial]))

      assert missing_identity["session_id"] == nil
      assert "missing_or_conflicting_native_identity" in missing_identity["protocol_errors"]
      assert "native_event_order" in missing_identity["protocol_errors"]
      refute missing_terminal["terminal_observed"]

      assert "missing_or_conflicting_successful_terminal" in missing_terminal["protocol_errors"]
    end
  end

  test "conflicting Claude init sessions and Codex thread identities are not chosen arbitrarily" do
    claude =
      Events.observe(
        "claude",
        stream([claude_init(), claude_init("other-session"), claude_result()])
      )

    codex =
      Events.observe(
        "codex",
        stream([codex_init(), codex_init("other-thread"), codex_terminal()])
      )

    for observed <- [claude, codex] do
      assert observed["session_id"] == nil
      assert "missing_or_conflicting_native_identity" in observed["protocol_errors"]
    end
  end

  test "Claude result must match the init session and conflicting models remain unknown" do
    mismatch =
      Events.observe(
        "claude",
        stream([claude_init(), Map.put(claude_result(), "session_id", "other-session")])
      )

    refute mismatch["terminal_observed"]
    assert "missing_or_conflicting_successful_terminal" in mismatch["protocol_errors"]

    conflicting_model =
      Events.observe(
        "claude",
        stream([
          claude_init(),
          Map.put(claude_init(), "model", "other-model"),
          claude_result()
        ])
      )

    assert conflicting_model["observed_model"] == nil
  end

  test "failed terminal events cannot establish successful completion despite accepting prose" do
    claude_failure =
      claude_result() |> Map.put("subtype", "error_during_execution") |> Map.put("is_error", true)

    codex_failure = %{"type" => "turn.failed", "error" => %{"message" => "provider failed"}}

    streams = [
      {"claude", [claude_init(), claude_failure]},
      {"codex", [codex_init(), codex_opinion(@opinion), codex_failure]},
      {"codex", [codex_init(), codex_opinion(@opinion), %{"type" => "error"}]}
    ]

    for {provider, events} <- streams do
      observed = Events.observe(provider, stream(events))
      refute observed["terminal_observed"]
      assert observed["opinion"] == @opinion
      assert "missing_or_conflicting_successful_terminal" in observed["protocol_errors"]
    end
  end

  test "conflicting or repeated terminal events are rejected even when one claims success" do
    for {provider, events} <- [
          {"claude",
           [claude_init(), claude_result(), Map.put(claude_result(), "total_cost_usd", 0.02)]},
          {"codex", [codex_init(), codex_terminal(), %{"type" => "turn.failed"}]},
          {"claude", [claude_init(), claude_result(), claude_result()]},
          {"codex", [codex_init(), codex_terminal(), codex_terminal()]}
        ] do
      observed = Events.observe(provider, stream(events))
      refute observed["protocol_errors"] == []
      assert "native_event_order" in observed["protocol_errors"]
    end
  end

  test "terminal precedes neither identity nor later command or assistant activity" do
    for provider <- ~w(claude codex) do
      {initial, terminal} = boundary(provider)

      activity =
        if provider == "codex",
          do: codex_command(),
          else: %{"type" => "assistant", "session_id" => "claude-session", "message" => %{}}

      for events <- [
            [terminal, initial],
            [activity, initial, terminal],
            [initial, terminal, activity]
          ] do
        observed = Events.observe(provider, stream(events))
        assert "native_event_order" in observed["protocol_errors"]
      end
    end
  end

  test "authored check declarations do not create native command receipts" do
    claims = Map.put(@opinion, "commands", [codex_command()["item"]])

    claude =
      Events.observe("claude", stream([claude_init(), claude_result(claims)]))

    codex =
      Events.observe("codex", stream([codex_init(), codex_opinion(claims), codex_terminal()]))

    for observed <- [claude, codex] do
      assert observed["opinion"] == claims
      assert observed["commands"] == []
      assert observed["protocol_errors"] == []
    end
  end

  test "an opinion must be an object whether delivered as structured data or JSON text" do
    for invalid <- ["plain prose", "[]", "null", "42", nil] do
      claude =
        Events.observe("claude", stream([claude_init(), claude_result(invalid)]))

      codex =
        Events.observe(
          "codex",
          stream([codex_init(), codex_opinion_text(invalid), codex_terminal()])
        )

      assert claude["opinion"] == nil
      assert codex["opinion"] == nil
    end

    text = Jason.encode!(@opinion)

    assert Events.observe("claude", stream([claude_init(), claude_result(text)]))["opinion"] ==
             @opinion
  end

  test "malformed typed item payloads are refused without losing the raw stream digest" do
    for invalid <- ["item prose", 7, nil, []] do
      raw =
        stream([
          codex_init(),
          %{"type" => "item.completed", "item" => invalid},
          codex_terminal()
        ])

      observed = Events.observe("codex", raw)
      assert "malformed_native_item" in observed["protocol_errors"]
      assert observed["commands"] == []
      assert observed["opinion"] == nil
      assert observed["stream_sha256"] == digest(raw)
    end
  end

  test "command receipts need nonblank immutable ids" do
    for item <- [
          Map.delete(codex_command()["item"], "id"),
          Map.put(codex_command()["item"], "id", ""),
          Map.put(codex_command()["item"], "id", "   ")
        ] do
      observed =
        Events.observe(
          "codex",
          stream([codex_init(), %{"type" => "item.completed", "item" => item}, codex_terminal()])
        )

      refute observed["protocol_errors"] == []
    end
  end

  test "conflicting command payloads cannot share the same immutable native item id" do
    observed =
      Events.observe(
        "codex",
        stream([
          codex_init(),
          codex_command(),
          codex_command(%{"exit_code" => 1}),
          codex_terminal()
        ])
      )

    refute observed["protocol_errors"] == []
  end

  test "distinct command ids retain repeated physical checks rather than deduplicating command text" do
    observed =
      Events.observe(
        "codex",
        stream([
          codex_init(),
          codex_command(),
          codex_command(%{"id" => "command-2"}),
          codex_terminal()
        ])
      )

    assert Enum.map(observed["commands"], & &1["id"]) == ["command-1", "command-2"]
    assert observed["protocol_errors"] == []
  end

  test "identical reemission of an immutable command item does not invent a conflict" do
    observed =
      Events.observe(
        "codex",
        stream([codex_init(), codex_command(), codex_command(), codex_terminal()])
      )

    assert Enum.uniq(observed["commands"]) == [Map.drop(codex_command()["item"], ["type"])]
    assert observed["protocol_errors"] == []
  end

  defp boundary("claude"), do: {claude_init(), claude_result()}
  defp boundary("codex"), do: {codex_init(), codex_terminal()}

  defp claude_init(session \\ "claude-session"),
    do: %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => session,
      "model" => "claude-sonnet-fixture"
    }

  defp claude_result(opinion \\ @opinion),
    do: %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "session_id" => "claude-session",
      "structured_output" => opinion,
      "usage" => %{"input_tokens" => 12, "output_tokens" => 7},
      "total_cost_usd" => 0.01
    }

  defp codex_init(thread \\ "codex-thread"),
    do: %{"type" => "thread.started", "thread_id" => thread}

  defp codex_terminal,
    do: %{"type" => "turn.completed", "usage" => %{"input_tokens" => 20, "output_tokens" => 10}}

  defp codex_command(overrides \\ %{}),
    do: %{
      "type" => "item.completed",
      "item" =>
        Map.merge(
          %{
            "id" => "command-1",
            "type" => "command_execution",
            "command" => "./check.sh",
            "cwd" => "/fixture",
            "aggregated_output" => "pinned check passed\n",
            "exit_code" => 0,
            "status" => "completed"
          },
          overrides
        )
    }

  defp codex_opinion(opinion), do: codex_opinion_text(Jason.encode!(opinion))

  defp codex_opinion_text(text),
    do: %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}

  defp stream(events), do: Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
