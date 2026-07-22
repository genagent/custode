defmodule Custode.OneShotReportTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  test "report notes carry machine-readable front-matter (#18)" do
    workspace = tmp_workspace!()
    _routine = routine_fixture!(workspace)
    inbox = Path.join(workspace, "inbox")

    job = %Oban.Job{
      id: 4242,
      args: %{
        "prompt" => "count the beans",
        "report_inbox" => inbox,
        "tag" => "beans"
      }
    }

    result = structured_result(%{"summary" => "42 beans", "count" => 42}, cost_usd: 0.07)
    :ok = Custode.OneShotJob.handle_result(result, job)

    assert [note] = Path.wildcard(Path.join(inbox, "job-4242-*"))
    content = File.read!(note)

    [_pre, fenced | _rest] = String.split(content, "```json custode-report\n")
    [json, _rest2] = String.split(fenced, "\n```")
    header = Jason.decode!(json)

    assert header["job"] == 4242
    assert header["tag"] == "beans"
    assert header["status"] == "ok"
    assert_in_delta header["cost_usd"], 0.07, 0.0001
    assert header["structured"]["count"] == 42
    assert content =~ "42 beans"
  end
end
