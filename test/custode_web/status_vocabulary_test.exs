defmodule CustodeWeb.StatusVocabularyTest do
  @moduledoc """
  One status vocabulary (#31 slice 1): a state carries the same word and the
  same color on the fleet tile, the agent page header and the feed.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import CustodeWeb.Components
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("sv-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine}
  end

  defp stub_routine_agent!(routine) do
    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(routine.id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(routine.id) end)
    :ok
  end

  describe "the vocabulary itself" do
    test "every status has a word and a color, and a gate does not change either" do
      assert Enum.sort(statuses()) ==
               Enum.sort([
                 :running,
                 :idle,
                 :awaiting_permission,
                 :waiting_for_user,
                 :paused,
                 :offline,
                 :ended
               ])

      for status <- statuses() do
        assert is_binary(status_label(status))
        assert status_label(status) != ""
        assert status_class(status) =~ "badge-"

        # a gated status arrives as {state, payload} and must read identically
        assert status_label({status, %{id: "a1"}}) == status_label(status)
        assert status_class({status, %{id: "a1"}}) == status_class(status)
      end
    end

    test "the machine atoms operators never asked for read as English" do
      assert status_label(:awaiting_permission) == "needs approval"
      assert status_label(:waiting_for_user) == "needs answer"
    end

    test "feed events that report a status borrow its word" do
      assert status_for_event("needs_approval") == :awaiting_permission
      assert status_for_event("needs_input") == :waiting_for_user
      assert status_for_event("budget_paused") == :paused
      assert status_for_event("turn") == nil
    end
  end

  describe "one word across all three views" do
    test "a gate reads 'needs approval' on the tile, the header and the feed",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      :processing = Agent.submit_prompt(routine.id, "gated")

      assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                     when enqueued_id == routine.id

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "act"})
        )

      {:ok, {:awaiting_permission, _action}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)

      Custode.Feed.record(%{event: "needs_approval", agent: routine.id, action: "act"})

      assert_same_word(conn, routine.id, :awaiting_permission, "awaiting_permission")
    end

    test "a question reads 'needs answer' on the tile, the header and the feed",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      :processing = Agent.submit_prompt(routine.id, "curious")

      assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                     when enqueued_id == routine.id

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "ask_user", "question" => "which env?"})
        )

      {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)
      Custode.Feed.record(%{event: "needs_input", agent: routine.id, question: "which env?"})

      assert_same_word(conn, routine.id, :waiting_for_user, "waiting_for_user")
    end

    # the label lands on every view, and the raw atom lands on none of them
    defp assert_same_word(conn, id, status, machine_word) do
      label = status_label(status)

      for path <- ["/", "/agents/#{id}", "/feed"] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ label, "#{path} does not say #{inspect(label)}"
        refute html =~ machine_word
      end
    end
  end

  describe "offline and ended" do
    test "an agent with a routine is offline until its first beat",
         %{conn: conn, routine: routine} do
      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "offline"
      assert html =~ "the next beat starts it"
      refute html =~ "ephemeral agent"
    end

    test "a stopped ephemeral with a trail has ended, not gone offline", %{conn: conn} do
      id = uid("ephemeral")
      Custode.Feed.record(%{event: "turn", agent: id, summary: "did one thing and stopped"})

      {:ok, _view, html} = live(conn, "/agents/#{id}")
      assert html =~ status_label(:ended)
      assert html =~ "ephemeral agent"
      refute html =~ "the next beat starts it"
    end

    test "an id with no trail at all stays offline -- nothing has ended", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/never-started")
      assert html =~ "offline"
      refute html =~ "ephemeral agent"
    end
  end
end
