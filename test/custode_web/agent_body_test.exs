defmodule CustodeWeb.AgentBodyTest do
  @moduledoc """
  The pluggable body (#302). `quakes` is the standing test: no repository, no
  diff, no checks, no pull requests, only a feed and a journal. A layout that
  cannot express it has let repository shape leak into the core.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("body") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    %{conn: build_conn(), workspace: tmp_workspace!()}
  end

  defp watcher!(workspace) do
    id = uid("watch")
    sensor_id = "sensor-" <> id

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "sweep", role: :quake_watch}
    ])

    put_env!(:sensors, [
      %{
        id: sensor_id,
        cron: "*/15 * * * *",
        module: Custode.Sensors.UsgsQuakes,
        notify: id,
        args: %{}
      }
    ])

    {id, sensor_id}
  end

  defp repo_agent!(workspace) do
    id = uid("repo")

    put_env!(:routines, [
      %{
        id: id,
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep",
        repo: "acme/" <> id,
        working_dir: workspace
      }
    ])

    id
  end

  describe "a watch agent" do
    test "gets a watching body, not an empty repository heading",
         %{conn: conn, workspace: workspace} do
      {id, sensor_id} = watcher!(workspace)

      {:ok, _view, html} = live(conn, "/agents/#{id}")

      assert html =~ "watching"
      assert html =~ sensor_id
      # the word the whole issue is about: no repository shape on a non-repo
      refute html =~ ">repository<"
    end

    test "shows what its sensors actually reported", %{conn: conn, workspace: workspace} do
      {id, _sensor_id} = watcher!(workspace)

      Custode.Feed.record(%{
        event: "sensor",
        agent: id,
        summary: "usgs-quakes: 12 new items, note dropped"
      })

      {:ok, _view, html} = live(conn, "/agents/#{id}")
      assert html =~ "12 new items"
    end

    test "says so plainly when nothing has been reported",
         %{conn: conn, workspace: workspace} do
      {id, _sensor_id} = watcher!(workspace)

      {:ok, _view, html} = live(conn, "/agents/#{id}")
      assert html =~ "nothing reported in this window"
    end
  end

  describe "a repo agent" do
    test "still gets the repository body", %{conn: conn, workspace: workspace} do
      id = repo_agent!(workspace)

      {:ok, _view, html} = live(conn, "/agents/#{id}")

      assert html =~ "repository"
      refute html =~ "nothing reported in this window"
    end
  end

  describe "one composer" do
    setup %{workspace: workspace} do
      routine = routine_fixture!(workspace)
      test_pid = self()

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            send(test_pid, {:enqueued, args, meta})
            {:ok, :queued}
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)
      %{routine: routine}
    end

    test "there is exactly one, and it means answer while a question is open",
         %{conn: conn, routine: routine} do
      :processing = Agent.submit_prompt(routine.id, "curious")

      assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                     when enqueued_id == routine.id

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "ask_user", "question" => "which env?"})
        )

      {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)

      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")

      # the page used to carry an answer box AND a prompt box, each with its
      # own file picker, for the same job
      assert count(html, "phx-submit=\"prompt\"") == 1
      refute html =~ "phx-submit=\"answer\""
      assert html =~ "your answer..."
    end

    test "and means prompt when no question is open", %{conn: conn, routine: routine} do
      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")

      assert count(html, "phx-submit=\"prompt\"") == 1
      assert html =~ "prompt #{routine.id}..."
      refute html =~ "your answer..."
    end
  end

  describe "the live question" do
    # The page renders the question in the attention block. The activity list
    # used to print it AGAIN as a needs_input entry, which made the audit
    # trail a second copy of current state. Tested on the filter directly:
    # counting the string across the whole page also catches the raw turn
    # result in the machine log, which is different content and not a
    # duplicate.
    test "is dropped from the activity trail while it is still open" do
      feed = [
        %{"event" => "needs_input", "question" => "which env?", "at" => "t2"},
        %{"event" => "turn", "summary" => "swept", "at" => "t1"}
      ]

      assert CustodeWeb.AgentLive.drop_live_question(feed, "which env?") == [
               %{"event" => "turn", "summary" => "swept", "at" => "t1"}
             ]
    end

    test "an ANSWERED question stays in the trail, because there it is the point" do
      feed = [%{"event" => "needs_input", "question" => "which env?", "at" => "t1"}]

      # nothing pending: nothing to deduplicate
      assert CustodeWeb.AgentLive.drop_live_question(feed, nil) == feed
    end

    test "only the live one goes; an older question with different text stays" do
      feed = [
        %{"event" => "needs_input", "question" => "which env?", "at" => "t2"},
        %{"event" => "needs_input", "question" => "an older one", "at" => "t1"}
      ]

      assert [%{"question" => "an older one"}] =
               CustodeWeb.AgentLive.drop_live_question(feed, "which env?")
    end

    test "the attention block still shows it", %{conn: conn, workspace: workspace} do
      routine = routine_fixture!(workspace)
      test_pid = self()

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            send(test_pid, {:enqueued, args, meta})
            {:ok, :queued}
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      :processing = Agent.submit_prompt(routine.id, "curious")

      assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                     when enqueued_id == routine.id

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "ask_user", "question" => "which env?"})
        )

      {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)

      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "needs answer"
      assert html =~ "which env?"
    end
  end

  defp count(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
