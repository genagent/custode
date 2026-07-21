defmodule CustodeWeb.FleetLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("lv-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine}
  end

  defp stub_routine_agent!(routine) do
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} = Agent.start_agent(routine.id, enqueue_fun: enqueue_fun)
    on_exit(fn -> Agent.stop_agent(routine.id) end)
    :ok
  end

  test "renders one tile per routine with a detail link, offline until its first beat",
       %{conn: conn, routine: routine} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "tile-#{routine.id}"
    assert html =~ ~s(href="/agents/#{routine.id}")
    assert html =~ "next beat starts it"
    assert html =~ "beat"
  end

  test "the tile shows the agent's last message and live status",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => routine.id}},
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => "swept the yard"},
              cost_usd: 0.1
            )
          )
      )

    {:ok, view, html} = live(conn, "/")
    assert html =~ "swept the yard"
    assert html =~ "idle"

    # a transition pushes the badge live
    :processing = Agent.submit_prompt(routine.id, "turn")
    assert render(view) =~ "running"
  end

  test "a permission gate renders inline on the tile and approve releases it",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    :processing = Agent.submit_prompt(routine.id, "gated work")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        routine.id,
        {:ok,
         structured_result(%{"directive" => "request_permission", "action" => "prune notes"})}
      )

    {:ok, {:awaiting_permission, _action}} = Agent.await(routine.id, :awaiting_permission, 1_000)

    {:ok, view, html} = live(conn, "/")
    assert html =~ "prune notes"

    view |> element("#tile-#{routine.id} button", "approve") |> render_click()

    assert_receive {:enqueued, %{"prompt" => "Approved: " <> _rest}, _meta}
    assert render(view) =~ "running"
  end

  test "a pending question points through to the detail page for the answer",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    :processing = Agent.submit_prompt(routine.id, "curious")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        routine.id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which env?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "which env?"
    assert html =~ "answer"
  end
end
