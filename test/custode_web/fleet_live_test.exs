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

  test "attention sorts first: a gated agent's tile precedes idle tiles, ringed and counted",
       %{conn: conn, routine: routine} do
    # a second routine, configured after the first, which will be the gated one
    second = %{
      id: uid("routine"),
      cron: "@daily",
      workspace: tmp_workspace!(),
      prompt: "sweep"
    }

    put_env!(:routines, [
      %{id: routine.id, cron: routine.cron, workspace: routine.workspace, prompt: routine.prompt},
      second
    ])

    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(second.id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(second.id) end)

    :processing = Agent.submit_prompt(second.id, "gated")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        second.id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "act"})}
      )

    {:ok, {:awaiting_permission, _action}} = Agent.await(second.id, :awaiting_permission, 1_000)

    {:ok, _view, html} = live(conn, "/")

    # the gated second routine sorts before the offline first routine
    {gated_at, _} = :binary.match(html, "tile-#{second.id}")
    {idle_at, _} = :binary.match(html, "tile-#{routine.id}")
    assert gated_at < idle_at

    assert html =~ "ring-warning"
    # a short attention list names its subjects instead of a bare count
    assert html =~ "#{second.id} needs approval"
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

defmodule CustodeWeb.FleetLiveTagsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  test "tag chips render and filter the grid (#51)" do
    conn = build_conn()
    workspace = tmp_workspace!()
    tagged = uid("tagged")
    plain = uid("plain")

    put_env!(:routines, [
      %{id: tagged, cron: "@daily", workspace: workspace, prompt: "sweep", tags: [:rust, :repo]},
      %{id: plain, cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    {:ok, view, html} = live(conn, "/")

    # chips from the union of tags; both tiles visible unfiltered
    assert has_element?(view, "button[phx-value-tag=rust]")
    assert has_element?(view, "button[phx-value-tag=repo]")
    assert html =~ "tile-#{tagged}"
    assert html =~ "tile-#{plain}"

    html = view |> element("button[phx-value-tag=rust]") |> render_click()
    assert html =~ "tile-#{tagged}"
    refute html =~ "tile-#{plain}"

    # clicking the active tag clears the filter
    html = view |> element("button[phx-value-tag=rust]") |> render_click()
    assert html =~ "tile-#{plain}"
  end
end

defmodule CustodeWeb.FleetLiveActivitySortTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("lv-sort") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "tiles sort by most recent activity, newest first, ahead of id order (#131)" do
    workspace = tmp_workspace!()
    # id order (older < recent) is the opposite of the activity order we seed
    older = uid("aaa")
    recent = uid("zzz")

    put_env!(:routines, [
      %{id: older, cron: "@daily", workspace: workspace, prompt: "sweep"},
      %{id: recent, cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    # seed sequentially so `recent` carries the newer feed timestamp
    Custode.Feed.record(%{event: "turn", agent: older, summary: "old news"})
    Process.sleep(5)
    Custode.Feed.record(%{event: "turn", agent: recent, summary: "fresh news"})

    {:ok, _view, html} = live(build_conn(), "/")

    {recent_at, _} = :binary.match(html, "tile-#{recent}")
    {older_at, _} = :binary.match(html, "tile-#{older}")

    # recent activity floats above the id-earlier tile
    assert recent_at < older_at
    assert html =~ "sorted by recent activity"
  end
end

defmodule CustodeWeb.FleetLiveBrakeTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  test "pause all / resume all round-trip the whole fleet (#14)" do
    first = start_stub_agent!()
    second = start_stub_agent!()
    conn = build_conn()

    {:ok, view, _html} = live(conn, "/")
    view |> element("button", "pause all") |> render_click()

    {:ok, :paused} = Agent.await(first, :paused, 1_000)
    {:ok, :paused} = Agent.await(second, :paused, 1_000)

    view |> element("button", "resume all") |> render_click()
    {:ok, :idle} = Agent.await(first, :idle, 1_000)
    {:ok, :idle} = Agent.await(second, :idle, 1_000)
  end

  test "a recently ended ephemeral gets a dimmed ended ghost tile (#11)" do
    id = uid("ephemeral")
    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(id,
        enqueue_fun: fn _args, _meta ->
          send(test_pid, :enqueued)
          {:ok, :queued}
        end
      )

    Custode.Feed.record(%{event: "turn", agent: id, summary: "did one thing"})
    :ok = Agent.stop_agent(id)

    # registry cleanup is async; wait until the fleet no longer sees it live
    Enum.find(1..50, fn _attempt ->
      Process.sleep(20)
      not Enum.any?(ObanClaude.Agent.list(), fn {agent_id, _s} -> agent_id == id end)
    end) || flunk("agent never left the registry")

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "tile-#{id}"
    assert html =~ "ended"
    assert html =~ "did one thing"
    assert html =~ "opacity-60"
  end
end
