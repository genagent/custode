defmodule CustodeWeb.ConsoleLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("console-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    # the rail draws the whole fleet, so the whole fleet has to be this test's
    Custode.Repo.query!("DELETE FROM asks")
    Custode.Repo.query!("DELETE FROM gates")
    Custode.Repo.query!("DELETE FROM disowned_prs")
    Custode.Host.reset()
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)

    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{id: uid("asker"), cron: "@daily", workspace: workspace, prompt: "sweep"},
      %{id: uid("sleeper"), cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    [asker, sleeper] = Custode.Routine.all()
    %{conn: build_conn(), asker: asker, sleeper: sleeper}
  end

  test "the rail groups the fleet by what it needs, and opens on what most needs you",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, _ask} = Asks.ask(asker.id, "is the uncommitted diff yours?")

    {:ok, _view, html} = live(conn, "/console")

    assert html =~ "needs you"
    assert html =~ "scheduled"
    assert html =~ asker.id
    assert html =~ sleeper.id
    # opened on the agent with the question, without being told to
    assert html =~ "is the uncommitted diff yours?"
    assert html =~ "1 need you"
  end

  test "selecting a subject shows its pane, and the rail filter narrows",
       %{conn: conn, asker: asker, sleeper: sleeper} do
    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")

    assert html =~ ~s(<h1 class="font-mono text-2xl font-bold">#{sleeper.id}</h1>)
    assert html =~ "@daily"

    html = view |> form("#rail-filter", %{"q" => "asker"}) |> render_change()
    assert html =~ ~s(href="/console/#{asker.id}")
    refute html =~ ~s(href="/console/#{sleeper.id}")
  end

  # #450: the agent page hides its composer for an offline agent
  test "an offline agent still has a message box, and it says what sending does",
       %{conn: conn, sleeper: sleeper} do
    {:ok, view, html} = live(conn, "/console/#{sleeper.id}")

    assert html =~ "start + send"
    assert html =~ "this starts a turn with your message"

    html = view |> form("form[phx-submit=message]", %{"text" => "look at 42"}) |> render_submit()
    assert html =~ "started a turn with your message"
  end

  test "a question is answered in place, from the item pane",
       %{conn: conn, asker: asker} do
    {:ok, ask} = Asks.ask(asker.id, "staging or prod?")

    {:ok, view, _html} = live(conn, "/console/#{asker.id}")

    view
    |> form("form[phx-submit=op]", %{"text" => "staging"})
    |> render_submit()

    assert %{status: "answered", answer: "staging"} = Asks.get(ask.id)
  end

  test "a failed doctor is on the console too", %{conn: conn} do
    Custode.Host.put_doctor({:failed, "claude auth: logged out"})
    on_exit(&Custode.Host.reset/0)

    {:ok, _view, html} = live(conn, "/console")
    assert html =~ "no agent can run: the boot doctor failed"
  end

  describe "the header" do
    # most of what the operator wants is a sentence to the caretaker (#451)
    test "tells custode from wherever you are, and says what happened", %{conn: conn} do
      workspace = tmp_workspace!()

      caretaker = uid("caretaker")

      put_env!(:routines, [
        %{id: caretaker, cron: "@daily", workspace: workspace, prompt: "sweep", tags: [:meta]},
        %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "sweep"}
      ])

      {:ok, view, html} = live(conn, "/console")
      assert html =~ "tell #{caretaker}..."

      html =
        view
        |> form("form[phx-submit=tell_custode]", %{"text" => "pause everything but mdbook-lint"})
        |> render_submit()

      # the caretaker is offline in a test, so it is started with the sentence
      assert html =~ "custode: started a turn with your message"
    end

    test "with no caretaker in the roster there is no box to type into", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")
      refute html =~ "phx-submit=\"tell_custode\""
    end

    test "presence toggles between present and a pinned away", %{conn: conn} do
      Custode.Presence.set(:present)
      on_exit(fn -> Custode.Presence.set(:auto) end)

      {:ok, view, html} = live(conn, "/console")
      assert html =~ "present"

      html = view |> element("button[phx-click=toggle_presence]") |> render_click()
      assert html =~ "away"
      assert {:away, _at, {:pinned, :away}} = Custode.Presence.explain()
    end

    test "the brake is in the fleet menu and reports what it did", %{conn: conn} do
      id = start_stub_agent!()

      {:ok, view, _html} = live(conn, "/console")
      html = view |> element("button[phx-click=pause_all]") |> render_click()

      assert html =~ ~r/paused \d+ agent/
      assert {:ok, :paused} = ObanClaude.Agent.await(id, :paused, 1_000)

      html = view |> element("button[phx-click=resume_all]") |> render_click()
      assert html =~ ~r/resumed \d+ agent/
    end
  end

  test "the config tab says who the agent is, and the turns tab is honest when empty",
       %{conn: conn, sleeper: sleeper} do
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    html = view |> element("button[phx-value-tab=config]") |> render_click()
    assert html =~ "sweeps on"
    assert html =~ "@daily"
    assert html =~ "standing orders"

    html = view |> element("button[phx-value-tab=turns]") |> render_click()
    assert html =~ "no machine log"
  end

  # seen on the live fleet: an offline agent's "last said" was three identical
  # sensor pings
  test "last said is what the agent said, and sensor pings are only a footnote",
       %{conn: conn, sleeper: sleeper} do
    for _n <- 1..3 do
      Custode.Feed.record(%{event: "sensor", agent: sleeper.id, summary: "ci: nothing new"})
    end

    {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ "nothing yet from the agent. Last sensor: ci: nothing new"

    Custode.Feed.record(%{event: "turn", agent: sleeper.id, summary: "3 todos queued"})

    {:ok, _view, html} = live(conn, "/console/#{sleeper.id}")
    assert html =~ "3 todos queued"
    refute html =~ "nothing yet"
  end

  test "the tabs switch the subject pane", %{conn: conn, sleeper: sleeper} do
    {:ok, view, _html} = live(conn, "/console/#{sleeper.id}")

    html = view |> element("button[phx-value-tab=notebook]") |> render_click()
    assert html =~ "journal"
    assert html =~ "nothing queued"

    html = view |> element("button[phx-value-tab=work]") |> render_click()
    assert html =~ "not tied to a repository"
  end
end
