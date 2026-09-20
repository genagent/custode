defmodule Custode.Gates.GrantTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias Custode.Gates.Grant
  alias Custode.MCP.RepoTools
  alias ObanClaude.Agent

  setup do
    path = Path.join(System.tmp_dir!(), uid("grant") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  # drives a stub agent to an open approval gate the way the engine does:
  # run:stop first, then job_finished
  defp gated_agent!(fields) do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    result =
      structured_result(
        Map.merge(%{"directive" => "request_permission", "action" => "do it"}, fields)
      )

    :ok =
      Ingest.handle_event(
        [:oban_claude, :run, :stop],
        %{cost_usd: 0.0},
        %{result: result, job: %{meta: %{"agent_id" => id}}},
        nil
      )

    :ok = Agent.job_finished(id, {:ok, result})
    {:ok, {:awaiting_permission, %{id: action_id}}} = Agent.await(id, :awaiting_permission, 1_000)
    eventually(fn -> assert [_gate] = Gates.open_gates(id) end)
    {id, action_id}
  end

  defp approved_agent!(fields) do
    {id, action_id} = gated_agent!(fields)
    :processing = Custode.approve_action(id, action_id, via: :cli)
    eventually(fn -> assert %{} = Gates.active_grant(id) end)
    id
  end

  defp outside(agent_id), do: Custode.Feed.recent_by_event("grant_outside", agent: agent_id)

  defp frame_for(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  describe "the live grant" do
    test "an approval is a grant while its continuation runs, and not after" do
      {id, action_id} = gated_agent!(%{"action_class" => "ready_pr"})
      assert Gates.active_grant(id) == nil

      :processing = Custode.approve_action(id, action_id, via: :cli)
      assert %{class: "ready_pr", detail: "do it"} = eventually(fn -> grant!(id) end)

      :ok = Agent.job_finished(id, {:ok, structured_result(%{"directive" => "none"})})
      {:ok, _status} = Agent.await(id, :idle, 1_000)
      eventually(fn -> assert Gates.active_grant(id) == nil end)
    end

    test "a rejection grants nothing" do
      {id, action_id} = gated_agent!(%{"action_class" => "ready_pr"})
      :rejected = Custode.reject_with_note(id, action_id, "not yet", via: :cli)
      assert Gates.active_grant(id) == nil
    end

    defp grant!(id) do
      assert %{} = grant = Gates.active_grant(id)
      grant
    end
  end

  describe "verdict/2" do
    test "a verb inside the approved class is within, one outside it is not" do
      id = approved_agent!(%{"action_class" => "ready_pr"})

      assert {:within, %{class: "ready_pr"}} = Grant.verdict(id, :ready_pr)
      assert {:outside_class, %{class: "ready_pr"}} = Grant.verdict(id, :merge_pr)
    end

    test "other and an undeclared class do not bound the verbs" do
      assert {:unbounded, _grant} =
               %{"action_class" => "other"} |> approved_agent!() |> Grant.verdict(:merge_pr)

      assert {:unbounded, %{class: nil}} = %{} |> approved_agent!() |> Grant.verdict(:merge_pr)
    end

    test "a write with nothing approved in flight has no grant" do
      assert {:no_grant, nil} = Grant.verdict(uid("sweeper"), :comment)
    end
  end

  describe "check/2" do
    test "observing: the verb proceeds and what was outside is recorded" do
      id = approved_agent!(%{"action_class" => "ready_pr"})

      assert Grant.check(id, :ready_pr) == :ok
      assert outside(id) == []

      assert Grant.check(id, :merge_pr) == :ok

      assert [
               %{"verb" => "merge_pr", "verdict" => "outside_class", "class" => "ready_pr"} =
                 entry
             ] =
               outside(id)

      assert entry["refused"] == false
      assert entry["summary"] =~ "merge_pr is outside what gate"
    end

    test "enforcing: the verb is refused with the rule named" do
      put_env!(:gate_grant_mode, :enforce)
      id = approved_agent!(%{"action_class" => "comment"})

      assert Grant.check(id, :comment) == :ok

      assert {:error, "gate grant: open_pr is outside what gate" <> _rest} =
               Grant.check(id, :open_pr)

      sweeper = uid("sweeper")
      assert {:error, message} = Grant.check(sweeper, :comment)
      assert message =~ "no approved action in flight"
      assert [%{"refused" => true, "verdict" => "no_grant"}] = outside(sweeper)
    end

    test "the operator is never checked" do
      put_env!(:gate_grant_mode, :enforce)
      assert Grant.check(nil, :merge_pr) == :ok
    end
  end

  describe "the repo write tools" do
    test "a refusal comes back as the tool's error, before the repository is reached" do
      put_env!(:gate_grant_mode, :enforce)
      frame = frame_for(uid("sweeper"))

      assert {:reply, response, ^frame} =
               RepoTools.Comment.execute(%{repo: "acme/unserved", number: 1, body: "hi"}, frame)

      assert response.isError
      assert inspect(response.content) =~ "gate grant: comment with no approved action in flight"
    end

    test "observing, the same call reaches the repository and is recorded" do
      sweeper = uid("sweeper")

      assert {:reply, response, _frame} =
               RepoTools.ReadyPr.execute(%{repo: "acme/unserved", number: 1}, frame_for(sweeper))

      # the repository's own refusal, not the grant's
      refute inspect(response.content) =~ "gate grant"
      assert [%{"verb" => "ready_pr", "verdict" => "no_grant"}] = outside(sweeper)
    end
  end
end
