defmodule CustodeWeb.AgentLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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
    |> form(".alert form[phx-submit=prompt]", %{"text" => "staging"})
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

  test "an unknown agent renders gracefully as offline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/never-started")
    assert html =~ "offline"
  end
end
