defmodule CustodeWeb.AgentLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Config.Loader
  alias Custode.Test.FakeGitHubFetcher
  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("al-feed") <> ".jsonl")
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

  # The routine's own raw entry parsed out of the roster file -- so an
  # assertion about a routine's baked fields ignores the [[profiles]] dump.
  defp raw_entry(roster, id) do
    {routines, _sensors, _profiles} = Loader.parse!(File.read!(roster), roster)
    Enum.find(routines, &(&1.id == id))
  end

  test "renders the whole picture: notebook, memory, activity, machine log",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    {:ok, _todo} = Custode.Notebook.todo_add(routine.id, "water the plants", source: "human")
    {:ok, _entry} = Custode.Notebook.journal_append(routine.id, "a good day", title: "weather")
    :ok = Custode.Memory.remember(routine.id, "pref", "be brief")

    :processing = Agent.submit_prompt(routine.id, "turn one")
    :ok = Agent.job_finished(routine.id, {:ok, result("did the thing")})
    {:ok, :idle} = Agent.await(routine.id, :idle, 1_000)

    {:ok, _view, html} = live(conn, "/agents/#{routine.id}")

    assert html =~ "water the plants"
    assert html =~ "a good day"
    assert html =~ "be brief"
    assert html =~ "turn one"
    assert html =~ "machine log"
  end

  test "prompt form, todo checkoff, and pause/resume work from the detail page",
       %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    {:ok, todo} = Custode.Notebook.todo_add(routine.id, "sharpen shears", source: "human")

    {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

    view |> form("form[phx-submit=prompt]", %{"text" => "from detail"}) |> render_submit()
    assert_receive {:enqueued, %{"prompt" => "from detail"}, _meta}
    html = render(view)
    assert html =~ "running"
    assert html =~ "sent -- turn starting"

    # a prompt while running acknowledges the queueing instead of silence
    view |> form("form[phx-submit=prompt]", %{"text" => "one more thing"}) |> render_submit()
    assert render(view) =~ "queued -- delivers when the current turn ends"

    # the queued prompt fires as its own turn once the first completes
    :ok = Agent.job_finished(routine.id, {:ok, result("first done")})
    assert_receive {:enqueued, %{"prompt" => "one more thing"}, _meta}

    :ok = Agent.job_finished(routine.id, {:ok, result("ok")})
    {:ok, :idle} = Agent.await(routine.id, :idle, 1_000)

    view |> element("button[phx-value-todo='#{todo.id}']") |> render_click()
    refute render(view) =~ "sharpen shears"

    view |> element("button", "pause") |> render_click()
    assert render(view) =~ "paused"
    view |> element("button", "resume") |> render_click()
    assert render(view) =~ "idle"
  end

  test "the answer form resolves a pending question", %{conn: conn, routine: routine} do
    stub_routine_agent!(routine)
    :processing = Agent.submit_prompt(routine.id, "curious")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        routine.id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which env?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)

    {:ok, view, html} = live(conn, "/agents/#{routine.id}")
    assert html =~ "which env?"

    view
    |> form("form[phx-submit=answer]", %{"text" => "staging"})
    |> render_submit()

    assert_receive {:enqueued, %{"prompt" => "staging"}, _meta}
  end

  test "a repo-tied routine grows repository panels that fill in live", %{conn: conn} do
    repo = "acme/" <> uid("panel")

    overview =
      FakeGitHubFetcher.overview(repo, %{
        open_issues: %{
          total: 42,
          items: [%{number: 465, title: "doctest all the things", url: "https://x", at: nil}]
        },
        open_prs: %{
          total: 2,
          items: [
            %{
              number: 589,
              title: "convert ignore to no_run",
              url: "https://x",
              at: nil,
              draft: true,
              checks: "PENDING"
            }
          ]
        },
        merged_prs: %{
          total: 7,
          items: [%{number: 583, title: "flat slot table", url: "https://x", at: nil}]
        }
      })

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{repo: repo})
    stub_routine_agent!(routine)

    # subscribe before mount: mounting kicks the async fetch whose broadcast
    # settles the race below
    Custode.PubSubBridge.subscribe()
    {:ok, view, html} = live(conn, "/agents/#{routine.id}")
    assert html =~ repo

    # the first render races the async fetch; the broadcast settles it
    html =
      if html =~ "doctest all the things" do
        html
      else
        assert_receive {:repo_overview, _repo}, 1_000
        render(view)
      end

    assert html =~ "42 open"
    assert html =~ "doctest all the things"
    assert html =~ "convert ignore to no_run"
    assert html =~ "draft"
    assert html =~ "recently merged"
    assert html =~ "flat slot table"
  end

  describe "agent-authored panels, gated (#100 v1)" do
    setup %{routine: routine} do
      previous = Application.get_env(:custode, :agent_panels)
      on_exit(fn -> Application.put_env(:custode, :agent_panels, previous) end)
      put_env!(:agent_panels, :gated)
      stub_routine_agent!(routine)
      :ok
    end

    test "a pending proposal shows a preview + approve; approve makes it current",
         %{conn: conn, routine: routine} do
      {:ok, _} = Custode.Panels.set(routine.id, "<b>proposed watchlist</b>")

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "panel update pending"
      assert has_element?(view, "button", "approve")

      view |> element("button", "approve") |> render_click()
      html = render(view)
      assert html =~ "agent-authored, approved"
      refute html =~ "panel update pending"
    end

    test "panel HTML renders ONLY inside a sandboxed iframe, never as live markup",
         %{conn: conn, routine: routine} do
      # a script tag in the panel must never become a live tag in the page
      {:ok, _} = Custode.Panels.set(routine.id, "<script>alert(1)</script><b>x</b>")
      :ok = Custode.Panels.approve(routine.id)

      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")

      # the iframe exists with an EMPTY sandbox (maximal restriction)
      assert html =~ ~s(sandbox="")
      # the panel content lives in srcdoc, HTML-attribute-escaped, so the
      # raw <script> never appears as a parseable tag in the page DOM
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "srcdoc="
    end

    test "reject clears the pending proposal", %{conn: conn, routine: routine} do
      {:ok, _} = Custode.Panels.set(routine.id, "<b>nope</b>")

      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")
      view |> element("button", "reject") |> render_click()

      refute render(view) =~ "panel update pending"
      assert Custode.Panels.current(routine.id) == nil
    end
  end

  describe "the working-state strip (#211)" do
    test "the latest worktree breadcrumb renders; a running turn shows in-flight",
         %{conn: conn, routine: routine} do
      repo = "acme/" <> uid("ws")
      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

      put_env!(
        :fake_repo_overviews,
        Map.put(overviews, repo, {:ok, FakeGitHubFetcher.overview(repo)})
      )

      routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
      stub_routine_agent!(routine)

      # a stop breadcrumb: work sitting on a branch, not in flight
      Custode.Feed.record(%{
        event: "worktree_state",
        agent: routine.id,
        phase: "stop",
        branch: "feat/thing",
        sha: "abc1234567def",
        added: 149,
        removed: 3
      })

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "feat/thing"
      assert html =~ "abc1234567"
      assert html =~ "+149"
      assert html =~ "-3"
      refute html =~ "working</span>"

      # a start breadcrumb newer than the stop: a turn is in flight now
      Custode.Feed.record(%{
        event: "worktree_state",
        agent: routine.id,
        phase: "start",
        branch: "feat/thing",
        sha: "abc1234567def"
      })

      assert render(view) =~ "working"
    end

    test "an absent worktree shows no strip", %{conn: conn, routine: routine} do
      repo = "acme/" <> uid("ws2")
      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

      put_env!(
        :fake_repo_overviews,
        Map.put(overviews, repo, {:ok, FakeGitHubFetcher.overview(repo)})
      )

      routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
      stub_routine_agent!(routine)

      Custode.Feed.record(%{
        event: "worktree_state",
        agent: routine.id,
        phase: "start",
        branch: "absent",
        sha: "absent"
      })

      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")
      refute html =~ "last worktree"
    end
  end

  describe "the agent panel (#100 slice 1)" do
    test "markdown under the panel key renders; raw HTML stays inert",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)

      :ok =
        Custode.Memory.remember(
          routine.id,
          "panel",
          "## watchlist\n\n| repo | state |\n|---|---|\n| tower | green |\n\n<script>alert(1)</script>"
        )

      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")

      assert html =~ "agent panel"
      assert html =~ "watchlist"
      assert html =~ "tower"
      # escape-before-parse: the script tag never survives as markup
      refute html =~ "<script>alert(1)</script>"
    end

    test "no panel memory, no section", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, _view, html} = live(conn, "/agents/#{routine.id}")
      refute html =~ "agent panel"
    end
  end

  describe "deeper browsing (#21)" do
    test "journal search narrows; clearing restores; older entries grow the list",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)

      for n <- 1..12 do
        {:ok, _} = Custode.Notebook.journal_append(routine.id, "routine sweep #{n}")
      end

      {:ok, _} = Custode.Notebook.journal_append(routine.id, "the heron landed on the dock")

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      # newest 10 of 13: the heron plus the last sweeps; sweep 1 is beyond
      assert html =~ "heron"
      refute html =~ "routine sweep 1<"

      html =
        view
        |> form("form[phx-change=journal_search]", %{"search" => "heron"})
        |> render_change()

      assert html =~ "the heron landed"
      refute html =~ "routine sweep 12"

      # no matches says so
      html =
        view
        |> form("form[phx-change=journal_search]", %{"search" => "walrus"})
        |> render_change()

      assert html =~ "(no matches)"

      # clear, then grow past the first page
      view
      |> form("form[phx-change=journal_search]", %{"search" => ""})
      |> render_change()

      html = view |> element("button", "older entries") |> render_click()
      assert html =~ "routine sweep 1"
    end

    test "done todos hide behind a toggle", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, todo} = Custode.Notebook.todo_add(routine.id, "finished chore", source: "test")
      {:ok, _} = Custode.Notebook.todo_complete(todo.id)
      {:ok, _} = Custode.Notebook.todo_add(routine.id, "open chore", source: "test")

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "open chore"
      refute html =~ "finished chore"

      html = view |> element("button", "show done") |> render_click()
      assert html =~ "finished chore"
    end

    test "forgetting a memory removes it", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      :ok = Custode.Memory.remember(routine.id, "stale-fact", "the old world")

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "the old world"

      view
      |> element("button[phx-value-key=stale-fact]")
      |> render_click()

      refute render(view) =~ "the old world"
      assert Custode.Memory.recall(routine.id, "stale-fact") == :error
    end

    test "older activity grows the feed window", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)

      for n <- 1..35 do
        Custode.Feed.record(%{event: "turn", agent: routine.id, summary: "wave #{n} rolled in"})
      end

      {:ok, view, html} = live(conn, "/agents/#{routine.id}")
      assert html =~ "wave 35"
      refute html =~ "wave 2 rolled"

      html = view |> element("button", "older activity") |> render_click()
      assert html =~ "wave 2 rolled"
    end
  end

  describe "the edit form (#174 slice 2)" do
    setup %{routine: routine} do
      roster = Path.join(System.tmp_dir!(), uid("edit-roster") <> ".toml")
      System.put_env("CUSTODE_CONFIG", roster)
      previous = Application.get_env(:custode, :routines)

      on_exit(fn ->
        System.delete_env("CUSTODE_CONFIG")
        File.rm(roster)
        Application.put_env(:custode, :routines, previous)
      end)

      stub_routine_agent!(routine)
      %{roster: roster}
    end

    test "opens prefilled from the raw entry and carries the migration warning",
         %{conn: conn, routine: routine} do
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      html = view |> element("button", "edit") |> render_click()

      # raw values, not normalized ones: cron shows, model (profile default
      # territory) is empty
      assert html =~ ~s(value="@daily")
      # no roster file yet: saving is the mode switch, said on the button
      assert html =~ "migrates your roster"
      assert html =~ "save (migrates roster to file)"
    end

    test "saving a change writes the file and the live roster; empty drops an override",
         %{conn: conn, routine: routine, roster: roster} do
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")
      view |> element("button", "edit") |> render_click()

      view
      |> form("#edit-agent-modal form", %{"routine" => %{"daily_budget_usd" => "75.5"}})
      |> render_submit()

      assert File.read!(roster) =~ ~s(daily_budget_usd = 75.5)
      assert Custode.Routine.get(routine.id).daily_budget_usd == 75.5
      # the raw entry stayed raw: no baked-in profile defaults. Checked on
      # the routine's own raw entry, not the whole file -- the file now also
      # carries the [[profiles]] dump (#236), which has its own max_turns.
      refute Map.has_key?(raw_entry(roster, routine.id), :max_turns)

      # re-open (fresh raw) and clear the override
      view |> element("button", "edit") |> render_click()

      view
      |> form("#edit-agent-modal form", %{"routine" => %{"daily_budget_usd" => ""}})
      |> render_submit()

      refute Map.has_key?(raw_entry(roster, routine.id), :daily_budget_usd)
    end

    test "a bad value is refused in place, typed fields intact", %{conn: conn, routine: routine} do
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")
      view |> element("button", "edit") |> render_click()

      html =
        view
        |> form("#edit-agent-modal form", %{"routine" => %{"daily_budget_usd" => "lots"}})
        |> render_submit()

      assert html =~ "must be a number"
      # the modal stayed open with the typed value bound (#176's lesson)
      assert html =~ ~s(value="lots")
    end

    test "remove takes the routine off the roster and navigates home",
         %{conn: conn, routine: routine} do
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")
      view |> element("button", "edit") |> render_click()

      view |> element("button", "remove agent") |> render_click()

      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "removed"
      assert Custode.Routine.get(routine.id) == nil
    end
  end

  describe "images dropped on the prompt box (#180 slice 1)" do
    # a 1x1 png, small enough to live inline
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
         )

    test "a dropped image lands in the workspace and its path rides the prompt",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=prompt]", :image, [
        %{name: "screenshot.png", content: @png, type: "image/png"}
      ])
      |> render_upload("screenshot.png")

      assert render(view) =~ "screenshot.png"

      view |> form("form[phx-submit=prompt]", %{"text" => "what is this"}) |> render_submit()

      assert_receive {:enqueued, %{"prompt" => prompt}, _meta}
      assert prompt =~ "what is this"
      assert prompt =~ "-- Read it before answering"

      [_, path] = Regex.run(~r/attached image: (\S+)/, prompt)
      assert Path.dirname(path) == Path.join(Path.expand(routine.workspace), "uploads")
      assert Path.extname(path) == ".png"
      assert File.read!(path) == @png
    end

    test "an image with no text sends on its own", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=prompt]", :image, [
        %{name: "shot.png", content: @png, type: "image/png"}
      ])
      |> render_upload("shot.png")

      view |> form("form[phx-submit=prompt]", %{"text" => ""}) |> render_submit()

      assert_receive {:enqueued, %{"prompt" => prompt}, _meta}
      assert String.starts_with?(prompt, "attached image: ")
    end

    test "an empty prompt with nothing attached still sends nothing",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view |> form("form[phx-submit=prompt]", %{"text" => "   "}) |> render_submit()

      refute_receive {:enqueued, _args, _meta}, 100
    end

    test "a pending image can be removed before sending", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=prompt]", :image, [
        %{name: "mistake.png", content: @png, type: "image/png"}
      ])
      |> render_upload("mistake.png")

      assert render(view) =~ "mistake.png"
      view |> element("button[phx-click=drop_image]") |> render_click()
      refute render(view) =~ "mistake.png"

      view |> form("form[phx-submit=prompt]", %{"text" => "never mind"}) |> render_submit()
      assert_receive {:enqueued, %{"prompt" => "never mind"}, _meta}
    end
  end

  describe "images dropped on the answer box (#180 slice 2)" do
    # @png is the same 1x1 defined by the slice 1 block above

    test "a dropped image lands in the workspace and its path rides the answer",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      ask!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=answer]", :answer_image, [
        %{name: "trace.png", content: @png, type: "image/png"}
      ])
      |> render_upload("trace.png")

      assert render(view) =~ "trace.png"

      view |> form("form[phx-submit=answer]", %{"text" => "this one"}) |> render_submit()

      assert_receive {:enqueued, %{"prompt" => prompt}, _meta}
      assert prompt =~ "this one"
      assert prompt =~ "-- Read it before answering"

      [_, path] = Regex.run(~r/attached image: (\S+)/, prompt)
      assert Path.dirname(path) == Path.join(Path.expand(routine.workspace), "uploads")
      assert File.read!(path) == @png
    end

    test "an image with no text answers on its own", %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      ask!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=answer]", :answer_image, [
        %{name: "shot.png", content: @png, type: "image/png"}
      ])
      |> render_upload("shot.png")

      view |> form("form[phx-submit=answer]", %{"text" => ""}) |> render_submit()

      assert_receive {:enqueued, %{"prompt" => prompt}, _meta}
      assert String.starts_with?(prompt, "attached image: ")
    end

    test "an image staged on one box does not ride the other's send",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      ask!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=prompt]", :image, [
        %{name: "elsewhere.png", content: @png, type: "image/png"}
      ])
      |> render_upload("elsewhere.png")

      view |> form("form[phx-submit=answer]", %{"text" => "staging"}) |> render_submit()

      assert_receive {:enqueued, %{"prompt" => answered}, _meta}
      assert answered == "staging"

      # the prompt box kept its image, and it rides that box's own send
      view |> form("form[phx-submit=prompt]", %{"text" => "and this"}) |> render_submit()
      :ok = Agent.job_finished(routine.id, {:ok, result("answered")})

      assert_receive {:enqueued, %{"prompt" => prompted}, _meta}
      assert prompted =~ "and this"
      assert prompted =~ "attached image: "
    end

    test "a pending answer image can be removed before sending",
         %{conn: conn, routine: routine} do
      stub_routine_agent!(routine)
      ask!(routine)
      {:ok, view, _html} = live(conn, "/agents/#{routine.id}")

      view
      |> file_input("form[phx-submit=answer]", :answer_image, [
        %{name: "mistake.png", content: @png, type: "image/png"}
      ])
      |> render_upload("mistake.png")

      assert render(view) =~ "mistake.png"
      view |> element("button[phx-value-upload=answer_image]") |> render_click()
      refute render(view) =~ "mistake.png"

      view |> form("form[phx-submit=answer]", %{"text" => "never mind"}) |> render_submit()
      assert_receive {:enqueued, %{"prompt" => "never mind"}, _meta}
    end
  end

  # park an agent on a question, which is what puts the answer box on screen
  defp ask!(routine) do
    :processing = Agent.submit_prompt(routine.id, "curious")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        routine.id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which env?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(routine.id, :waiting_for_user, 1_000)
    :ok
  end

  test "an unknown agent renders gracefully as offline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/never-started")
    assert html =~ "offline"
  end
end
