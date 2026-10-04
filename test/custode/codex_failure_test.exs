defmodule Custode.CodexFailureTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Result
  alias Custode.CodexFailure

  test "merged command stdout survives nil, empty and whitespace-only stderr" do
    diagnostic = "Error: selected model is not supported by this account"
    result = Result.from_cmd({diagnostic, 1})

    for stderr <- [nil, "", " \n\t"] do
      assert CodexFailure.detail(%{result | stderr: stderr}) == "exit 1: " <> diagnostic
    end

    assert CodexFailure.detail(%{result | stderr: "codex failed to connect"}) ==
             "exit 1: codex failed to connect"
  end

  test "last terminal error wins over ordinary events and later transient errors" do
    result =
      json_result([
        %{"type" => "thread.started", "thread_id" => "not-a-diagnostic"},
        %{"type" => "turn.failed", "error" => %{"message" => "old failure"}},
        %{"type" => "item.completed", "item" => %{"text" => "Error: PRIVATE_ASSISTANT_TEXT"}},
        %{"type" => "config", "message" => "Error: PRIVATE_CONFIGURATION"},
        %{"type" => "turn.failed", "error" => %{"message" => "Selected model is unsupported"}},
        %{"type" => "error", "message" => "later transport noise"}
      ])

    assert CodexFailure.detail(result) == "exit 1: Selected model is unsupported"
  end

  test "typed error events are useful without a terminal event" do
    result =
      json_result([
        %{"type" => "error", "message" => "initial failure"},
        %{"type" => "error", "message" => "Model access is unavailable"},
        %{"type" => "error", "message" => %{"body" => "PRIVATE_UNEXPECTED_SHAPE"}}
      ])

    assert CodexFailure.detail(result) == "exit 1: Model access is unavailable"
  end

  test "plain diagnostic lines after a long preamble survive, without command or prompt dumps" do
    noise =
      String.duplicate("configuration preamble\n", 400) <>
        "codex exec --model invalid-model 'PRIVATE_OPERATOR_PROMPT'\n" <>
        "prompt: Error: PRIVATE_PROMPT_DUMP\n" <>
        "developer_instructions=\"Error: PRIVATE_CONFIGURATION\"\n" <>
        "I cannot finish PRIVATE_ASSISTANT_PROSE\n"

    assert CodexFailure.detail(Result.from_cmd({noise <> "Error: model unsupported\n", 2})) ==
             "exit 2: Error: model unsupported"

    for stdout <- [
          noise,
          ~s({"type":"error","message":"PRIVATE_MALFORMED"),
          ~s("Error: PRIVATE_JSON_STRING")
        ] do
      assert CodexFailure.detail(Result.from_cmd({stdout, 2})) ==
               "exit 2: Codex exited unsuccessfully without a diagnostic"
    end
  end

  test "even typed or prefixed errors cannot echo command arguments or prompt configuration" do
    for message <- [
          "Error running command: codex exec --model foo 'PRIVATE_ECHO'",
          "Error: could not launch codex exec --model foo 'PRIVATE_ECHO'",
          "Error: invalid developer_instructions=PRIVATE_ECHO",
          "Error: prompt PRIVATE_ECHO was rejected",
          "Error: configuration: PRIVATE_ECHO",
          ~S(Error: {"command":["codex","exec","PRIVATE_ECHO"]}),
          ~S(Error: {\"command\":[\"codex\",\"exec\",\"PRIVATE_ECHO\"]})
        ] do
      for result <- [
            Result.from_cmd({message, 1}),
            json_result([%{"type" => "error", "message" => message}])
          ] do
        detail = CodexFailure.detail(result)
        assert detail =~ "exit 1: Error"
        assert detail =~ "[command/configuration detail omitted]"
        refute detail =~ "PRIVATE_ECHO"
      end
    end
  end

  test "output-free and malformed structured failures retain the exit code safely" do
    for stdout <- [nil, "", " \t\n", ~s({"type":"turn.failed","error":{"message":null}})] do
      result = %Result{success: false, exit_code: 127, stdout: stdout, stderr: ""}

      assert CodexFailure.detail(result) ==
               "exit 127: Codex exited unsuccessfully without a diagnostic"
    end
  end

  test "credential-bearing suffixes are removed before any value parsing or byte bound" do
    for sensitive <- [
          "Authorization: Bearer SECRET_SENTINEL",
          ~S(mcp_servers.custode.http_headers.Authorization=\"Bearer SECRET_SENTINEL\"),
          ~S({\"Authorization\":\"Bearer SECRET_SENTINEL with spaces\"}),
          "Bearer SECRET_SENTINEL",
          "OPENAI_API_KEY='SECRET_SENTINEL with spaces'",
          ~S(\"apiKey\"=\"SECRET_SENTINEL\"),
          "access_token=SECRET_SENTINEL",
          "CUSTODE_OPERATOR_TOKEN=\"SECRET_SENTINEL\"",
          "refresh-token:\nSECRET_SENTINEL",
          "password=SECRET_SENTINEL"
        ] do
      result = json_result([%{"type" => "error", "message" => "Request failed: " <> sensitive}])
      detail = CodexFailure.detail(result)
      assert detail =~ "exit 1: Request failed: "
      assert detail =~ "omitted]"
      refute detail =~ "SECRET_SENTINEL"
    end

    prefix = String.duplicate("x", 1900)
    secret = "CROSSING_SECRET_" <> String.duplicate("z", 1000)
    result = Result.from_cmd({"Error: #{prefix} Authorization: Bearer #{secret}", 1})
    detail = CodexFailure.detail(result)
    assert byte_size(detail) <= 2048
    refute detail =~ "CROSSING_SECRET"
    refute detail =~ String.duplicate("z", 10)
  end

  test "terminal sequences and invalid UTF-8 cannot hide credentials or break projection" do
    text =
      "\e]0;PRIVATE_WINDOW_TITLE\a\e[31mError: model unsupported\e[0m " <>
        <<255>> <> " Auth\e[32morization: Bearer SECRET_CONTROL"

    detail = CodexFailure.detail(Result.from_cmd({text, 1}))
    assert detail =~ "Error: model unsupported"
    assert String.valid?(detail)
    refute detail =~ <<27>>
    refute detail =~ "PRIVATE_WINDOW_TITLE"
    refute detail =~ "SECRET_CONTROL"

    osc = "\e]8;;https://example.invalid/private\e\\Error: missing model\e]8;;\e\\"
    assert CodexFailure.detail(Result.from_cmd({osc, 1})) == "exit 1: Error: missing model"
  end

  test "the final byte bound preserves Unicode and marks truncation" do
    result = Result.from_cmd({"Error: " <> String.duplicate("é界", 1000), 9})
    detail = CodexFailure.detail(result)

    assert byte_size(detail) <= 2048
    assert String.valid?(detail)
    assert String.starts_with?(detail, "exit 9: Error: ")
    assert String.ends_with?(detail, "\n[truncated]")
    assert detail == CodexFailure.detail(result)
  end

  defp json_result(events) do
    events
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> then(&Result.from_cmd({&1, 1}))
  end
end
