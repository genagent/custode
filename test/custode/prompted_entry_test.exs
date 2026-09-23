defmodule Custode.PromptedEntryTest do
  # The prompted feed entry (#187): operator prompts land in the activity at
  # submit time; agent-to-sub-agent delegation does not.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.MCP.Tools.PromptAgent

  @endpoint CustodeWeb.Endpoint
  @operator %Anubis.Server.Frame{}

  setup do
    path = Path.join(System.tmp_dir!(), uid("prompted-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp agent_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  test "the console message submit records a prompted entry" do
    workspace = tmp_workspace!()
    id = uid("routine")
    put_env!(:routines, [%{id: id, cron: :manual, workspace: workspace, prompt: "x"}])
    {:ok, _pid} = ObanClaude.Agent.start_agent(id, enqueue_fun: fn _a, _m -> {:ok, :queued} end)

    {:ok, view, _html} = live(build_conn(), "/console/#{id}")
    render_submit(view, "message", %{"text" => "how are the hexagons?"})

    assert [entry | _rest] =
             Custode.Feed.for_agent(id) |> Enum.filter(&(&1["event"] == "prompted"))

    assert entry["prompt"] == "how are the hexagons?"
    assert entry["summary"] =~ "operator prompted"
  end

  test "the MCP tool records for the operator but not for agent callers" do
    workspace = tmp_workspace!()
    target = uid("target")
    put_env!(:routines, [%{id: target, cron: :manual, workspace: workspace, prompt: "x"}])

    {:ok, _pid} =
      ObanClaude.Agent.start_agent(target, enqueue_fun: fn _a, _m -> {:ok, :queued} end)

    PromptAgent.execute(%{agent_id: target, prompt: "from the operator"}, @operator)
    PromptAgent.execute(%{agent_id: target, prompt: "from a sibling"}, agent_frame("boss"))

    prompted = Custode.Feed.for_agent(target) |> Enum.filter(&(&1["event"] == "prompted"))
    assert [entry] = prompted
    assert entry["prompt"] == "from the operator"
  end
end
