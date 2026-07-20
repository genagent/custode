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

  # Replace the offline routine agent with a same-id observable stub.
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

  test "renders the routine card, offline until its first beat", %{conn: conn, routine: routine} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ routine.id
    assert html =~ "offline"
    assert html =~ "beat"
  end

  test "a running agent shows its badge and ledger; a prompt submits through the form",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "idle"

    view
    |> form("#agent-#{routine.id} form", %{"text" => "from the dashboard"})
    |> render_submit()

    assert_receive {:enqueued, %{"prompt" => "from the dashboard"}, _meta}

    # the transition broadcast pushes the badge to running without a reload
    assert render(view) =~ "running"
  end

  test "a permission gate renders inline and approve releases it",
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
    assert html =~ "wants permission"
    assert html =~ "prune notes"

    view |> element("#agent-#{routine.id} button", "approve") |> render_click()

    assert_receive {:enqueued, %{"prompt" => "Approved: " <> _rest}, _meta}
    assert render(view) =~ "running"
  end

  test "a pending question renders with an inline answer form", %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    :processing = Agent.submit_prompt(routine.id, "curious work")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        routine.id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which env?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)

    {:ok, view, html} = live(conn, "/")
    assert html =~ "which env?"

    view
    |> element("#agent-#{routine.id} .alert form")
    |> render_submit(%{"text" => "staging"})

    assert_receive {:enqueued, %{"prompt" => "staging"}, _meta}
  end

  test "pause and resume from the card", %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#agent-#{routine.id} button", "pause") |> render_click()
    assert render(view) =~ "paused"

    view |> element("#agent-#{routine.id} button", "resume") |> render_click()
    assert render(view) =~ "idle"
  end

  test "feed entries stream in live", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => "streamer"}},
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => "live wire"}, cost_usd: 0.1)
          )
      )

    assert render(view) =~ "live wire"
  end
end
