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

defmodule CustodeWeb.HierarchyPassTest do
  # The #31 visibility pass: one palette meaning per color, ambient states
  # demoted to muted text, pauses saying why, and failing PR checks
  # promoted to the tile (rank 1). guides/ui-hierarchy.md is the contract.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Test.FakeGitHubFetcher
  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("hier-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "wants-you states share the warning family; ambient states carry no badge" do
    import CustodeWeb.Components

    assert status_class(:awaiting_permission) == status_class(:waiting_for_user)
    assert status_class(:awaiting_permission) =~ "warning"
    assert status_class(:running) =~ "info"
    assert status_class(:paused) =~ "error"
  end

  test "an idle tile renders its state as muted text, not a badge box", %{} do
    workspace = tmp_workspace!()
    id = uid("calm")
    put_env!(:routines, [%{id: id, cron: "@daily", workspace: workspace, prompt: "s"}])
    {:ok, _pid} = Agent.start_agent(id, enqueue_fun: fn _a, _m -> {:ok, :q} end)
    on_exit(fn -> Agent.stop_agent(id) end)

    {:ok, view, _html} = live(build_conn(), "/")
    tile = element(view, "#tile-#{id}") |> render()
    assert tile =~ "idle"
    # the word is there; the badge box is not (rank-4 never shouts)
    refute tile =~ ~r/badge[^>]*>\s*idle/
  end

  test "a budget pause says why on the tile" do
    workspace = tmp_workspace!()
    id = uid("broke")

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "s", daily_budget_usd: 0.05}
    ])

    {:ok, _pid} = Agent.start_agent(id, enqueue_fun: fn _a, _m -> {:ok, :q} end)
    on_exit(fn -> Agent.stop_agent(id) end)
    :ok = Custode.SpendLedger.record(id, 0.10)
    :ok = Agent.emergency_pause(id)
    {:ok, :paused} = Agent.await(id, :paused, 1_000)

    {:ok, view, _html} = live(build_conn(), "/")
    tile = element(view, "#tile-#{id}") |> render()
    assert tile =~ "paused"
    assert tile =~ "daily rail"
  end

  test "failing checks on an agent PR surface on its tile as a rank-1 chip" do
    repo = "acme/" <> uid("red")

    overview =
      FakeGitHubFetcher.overview(repo, %{
        open_prs: %{
          total: 2,
          items: [
            %{
              number: 9,
              title: "red",
              url: "https://x",
              at: nil,
              draft: false,
              checks: "FAILURE"
            },
            %{
              number: 8,
              title: "green",
              url: "https://x",
              at: nil,
              draft: false,
              checks: "SUCCESS"
            }
          ]
        }
      })

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

    workspace = tmp_workspace!()
    id = uid("checked")

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "s", repo: repo}
    ])

    {:ok, _pid} = Agent.start_agent(id, enqueue_fun: fn _a, _m -> {:ok, :q} end)
    on_exit(fn -> Agent.stop_agent(id) end)

    # warm the cache so the tile's read is a hit (the page itself reads
    # cache-only and fills in on the broadcast)
    Custode.PubSubBridge.subscribe()
    {:ok, view, _html} = live(build_conn(), "/")

    first = render(view)

    tile =
      if first =~ "red check" do
        first
      else
        assert_receive {:repo_overview, _repo}, 1_000
        render(view)
      end

    assert tile =~ "1 red check(s)"
  end
end

defmodule CustodeWeb.FleetMetaRailTest do
  # The caretaker's rail (#178): the meta agent has a place, not a slot, and
  # the fleet-level readouts moved out of the shared header into it.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ObanClaude.Agent

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("lv-rail") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "a :meta routine renders in the rail regardless of activity; workers never do" do
    workspace = tmp_workspace!()
    caretaker = uid("caretaker")
    worker = uid("worker")

    put_env!(:routines, [
      %{id: caretaker, cron: "@daily", workspace: workspace, prompt: "tend", tags: [:meta]},
      %{id: worker, cron: "@daily", workspace: workspace, prompt: "sweep", tags: [:repo]}
    ])

    # the worker is the only agent with any activity at all, so the activity
    # sort would have buried the quiet caretaker at the bottom of the grid
    Custode.Feed.record(%{event: "turn", agent: worker, summary: "fresh news"})

    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, "#meta-rail #tile-#{caretaker}")
    refute has_element?(view, ".grid #tile-#{caretaker}")

    assert has_element?(view, ".grid #tile-#{worker}")
    refute has_element?(view, "#meta-rail #tile-#{worker}")
    assert html =~ "fresh news"

    # the chips filter the grid, so :meta is not offered as one, and a filter
    # that empties the grid still leaves the caretaker in place
    refute has_element?(view, "button[phx-value-tag=meta]")
    html = view |> element("button[phx-value-tag=repo]") |> render_click()
    assert html =~ "tile-#{caretaker}"
  end

  test "the fleet spend readout lives in the rail, not the header" do
    workspace = tmp_workspace!()
    put_env!(:routines, [%{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "s"}])

    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, "#meta-rail", "fleet today")
    refute has_element?(view, "header", "fleet today")

    # the rail still renders without a :meta routine -- it holds the readouts
    assert has_element?(view, "#meta-rail", "no :meta agent configured")

    # other pages keep the readouts in their header
    {:ok, feed_view, _html} = live(build_conn(), "/feed")
    assert has_element?(feed_view, "header", "fleet today")
  end

  test "the needs-attention chip moved into the rail with the rest of the readouts" do
    workspace = tmp_workspace!()
    gated = uid("gated")
    put_env!(:routines, [%{id: gated, cron: "@daily", workspace: workspace, prompt: "s"}])

    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(gated,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(gated) end)

    :processing = Agent.submit_prompt(gated, "gated work")
    assert_receive {:enqueued, _args, _meta}

    :ok =
      Agent.job_finished(
        gated,
        {:ok,
         ObanClaude.Testing.structured_result(%{
           "directive" => "request_permission",
           "action" => "act"
         })}
      )

    {:ok, {:awaiting_permission, _action}} = Agent.await(gated, :awaiting_permission, 1_000)

    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, "#meta-rail a[href='/']", "#{gated} needs approval")
    refute has_element?(view, "header .badge-warning")
  end

  test "the in-flight section lists executing turns with elapsed, longest first (#211)" do
    workspace = tmp_workspace!()
    fast = uid("fast")
    slow = uid("slow")
    put_env!(:routines, [%{id: fast, cron: "@daily", workspace: workspace, prompt: "s"}])

    # seed the clock directly: slow started earlier, so it sorts first
    :ets.insert(:custode_run_clock, {slow, DateTime.add(DateTime.utc_now(), -400)})
    :ets.insert(:custode_run_clock, {fast, DateTime.add(DateTime.utc_now(), -10)})

    on_exit(fn ->
      :ets.delete(:custode_run_clock, slow)
      :ets.delete(:custode_run_clock, fast)
    end)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "in flight (2)"
    # both listed; the long-running one carries a warning tone (>= 5m)
    assert html =~ slow
    assert html =~ fast
    {slow_at, _} = :binary.match(html, slow)
    {fast_at, _} = :binary.match(html, fast)
    assert slow_at < fast_at

    # a calm fleet shows no in-flight section
    :ets.delete(:custode_run_clock, slow)
    :ets.delete(:custode_run_clock, fast)
    {:ok, _view2, html2} = live(build_conn(), "/")
    refute html2 =~ "in flight ("
  end

  test "an agent approaching its rail gets a banner; paused and calm agents do not (#211)" do
    workspace = tmp_workspace!()
    hot = uid("hot")
    calm = uid("calm")

    put_env!(:routines, [
      %{id: hot, cron: "@daily", workspace: workspace, prompt: "s", daily_budget_usd: 10.0},
      %{id: calm, cron: "@daily", workspace: workspace, prompt: "s", daily_budget_usd: 10.0}
    ])

    # 85% of the rail: approaching, not yet paused
    :ok = Custode.SpendLedger.record(hot, 8.5)
    :ok = Custode.SpendLedger.record(calm, 1.0)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "85%"
    assert html =~ "of its daily rail"
    refute html =~ "#{calm}\n        </a>\n        at"

    # the banner names the timezone the rails roll on
    tz = Application.get_env(:custode, :timezone, "Etc/UTC")
    assert html =~ tz
  end

  test "the caretaker is a rail resident with a standing prompt box" do
    workspace = tmp_workspace!()
    keeper = uid("keeper")
    test_pid = self()

    put_env!(:routines, [
      %{id: keeper, cron: "@daily", workspace: workspace, prompt: "tend", tags: [:meta]}
    ])

    {:ok, _pid} =
      ObanClaude.Agent.start_agent(keeper,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> ObanClaude.Agent.stop_agent(keeper) end)

    {:ok, view, html} = live(build_conn(), "/")

    # the rail holds a prompt form for the caretaker, not a bare tile
    assert has_element?(view, "#meta-rail form[phx-submit=rail_prompt]")
    assert html =~ "tell #{keeper}"

    view
    |> form("#meta-rail form[phx-submit=rail_prompt]", %{"text" => "how goes the fleet?"})
    |> render_submit()

    assert_receive {:enqueued, %{"prompt" => "how goes the fleet?"}, _meta}

    # blank never sends
    view
    |> form("#meta-rail form[phx-submit=rail_prompt]", %{"text" => "   "})
    |> render_submit()

    refute_receive {:enqueued, _args, _meta}, 100
  end

  describe "advisor suggestion cards" do
    defp suggest!(agent, field, opts \\ []) do
      Custode.Feed.record(%{
        event: "advisor_suggestion",
        agent: agent,
        advisor: opts[:advisor] || "advisor-cadence",
        field: field,
        current: opts[:current] || "@hourly",
        proposed: opts[:proposed] || "@daily",
        confidence: "medium",
        evidence: opts[:evidence] || "swept 12 times, changed nothing 11 of them",
        summary: "suggests #{agent}: #{field}"
      })
    end

    defp backdate_last!(days) do
      [[id]] = Custode.Repo.query!("SELECT id FROM feed_entries ORDER BY id DESC LIMIT 1").rows
      at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()
      Custode.Repo.query!("UPDATE feed_entries SET at = ? WHERE id = ?", [at, id])
    end

    test "a suggestion renders in the rail with its evidence, not in the grid" do
      workspace = tmp_workspace!()
      worker = uid("worker")
      put_env!(:routines, [%{id: worker, cron: "@daily", workspace: workspace, prompt: "s"}])

      suggest!(worker, "cron", evidence: "swept 12 times, changed nothing 11 of them")

      {:ok, view, _html} = live(build_conn(), "/")

      card = "#meta-rail #advisor-suggestions"
      assert has_element?(view, card, "cron")
      assert has_element?(view, card, "@daily")
      # the reasoning rides its own field, so the card shows it without
      # taking a summary sentence apart
      assert has_element?(view, card, "changed nothing 11 of them")

      # a suggestion is fleet-level information: it belongs to the rail, and
      # the worker's tile down in the grid is not where the operator reads it
      refute has_element?(view, ".grid", "changed nothing 11 of them")
    end

    test "the newest suggestion per field wins and stale ones age out of the rail" do
      workspace = tmp_workspace!()
      worker = uid("worker")
      put_env!(:routines, [%{id: worker, cron: "@daily", workspace: workspace, prompt: "s"}])

      suggest!(worker, "cron", proposed: "@weekly", evidence: "the old read")
      suggest!(worker, "cron", proposed: "@daily", evidence: "the current read")

      suggest!(worker, "daily_budget_usd", proposed: "9.99", evidence: "long forgotten")
      backdate_last!(30)

      {:ok, view, _html} = live(build_conn(), "/")

      card = "#meta-rail #advisor-suggestions"
      # one card per (advisor, agent, field), carrying the freshest read
      assert has_element?(view, card, "the current read")
      refute has_element?(view, card, "the old read")

      # with no accept/dismiss yet, the window is what keeps the rail honest
      refute has_element?(view, card, "long forgotten")
    end

    test "apply writes the change through the roster write-back and clears the card (#192)" do
      roster = Path.join(System.tmp_dir!(), uid("apply-roster") <> ".toml")
      System.put_env("CUSTODE_CONFIG", roster)
      previous = Application.get_env(:custode, :routines)

      on_exit(fn ->
        System.delete_env("CUSTODE_CONFIG")
        File.rm(roster)
        Application.put_env(:custode, :routines, previous)
      end)

      workspace = tmp_workspace!()
      worker = uid("worker")
      put_env!(:routines, [%{id: worker, cron: "@daily", workspace: workspace, prompt: "s"}])

      Custode.Repo.query!("DELETE FROM feed_entries WHERE event = 'advisor_suggestion'")
      suggest!(worker, "model", advisor: "advisor-model", current: "opus", proposed: "sonnet")

      {:ok, view, _html} = live(build_conn(), "/")
      assert has_element?(view, "#advisor-suggestions button", "apply")

      view
      |> element("#advisor-suggestions button[phx-value-field=model]")
      |> render_click()

      # the write landed: file created (the mode switch), entry edited, live
      assert File.read!(roster) =~ ~s(model = "sonnet")
      assert Custode.Routine.get(worker).model == "sonnet"

      # the card left the rail even though the suggestion entry remains
      refute has_element?(view, "#advisor-suggestions", "sonnet")

      # and the application is on the record
      assert Enum.any?(
               Custode.Feed.for_agent(worker),
               &(&1["event"] == "advisor_applied" and &1["proposed"] == "sonnet")
             )
    end

    test "no suggestions means no section at all" do
      workspace = tmp_workspace!()

      put_env!(:routines, [
        %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "s"}
      ])

      # the feed table outlives a single test, so an empty rail has to be
      # asked for explicitly rather than assumed
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event = 'advisor_suggestion'")

      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, "#meta-rail")
      refute has_element?(view, "#advisor-suggestions")
    end
  end
end

defmodule CustodeWeb.FleetLiveNewAgentTest do
  # The dashboard new-agent form (#75 / design 001 slice 4): human authority
  # driving WriteBack -- live TOML preview, then file + roster in one submit.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    roster = Path.join(System.tmp_dir!(), uid("form-roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", roster)
    previous = Application.get_env(:custode, :routines)
    feed = Path.join(System.tmp_dir!(), uid("form-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(roster)
      File.rm(feed)
      Application.put_env(:custode, :routines, previous)
    end)

    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{id: uid("seed"), cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    %{roster: roster}
  end

  test "the form previews the literal TOML and the submit lands it live", %{roster: roster} do
    {:ok, view, _html} = live(build_conn(), "/")

    render_click(view, "new_agent_open")

    html =
      render_change(view, "new_agent_change", %{
        "routine" => %{
          "id" => "form-worker",
          "profile" => "backlog_worker",
          "repo" => "o/r",
          "working_dir" => "/tmp/o",
          "tags" => "rust"
        }
      })

    assert html =~ "this exact text lands in routines.toml"
    assert html =~ "id = &quot;form-worker&quot;"

    render_submit(view, "new_agent_create", %{
      "routine" => %{
        "id" => "form-worker",
        "profile" => "backlog_worker",
        "repo" => "o/r",
        "working_dir" => "/tmp/o",
        "tags" => "rust"
      }
    })

    assert File.exists?(roster)
    assert Custode.Routine.get("form-worker").role == :backlog_worker
  end

  test "a bad profile disables the submit with a message, not a crash" do
    {:ok, view, _html} = live(build_conn(), "/")

    render_click(view, "new_agent_open")

    html =
      render_change(view, "new_agent_change", %{
        "routine" => %{"id" => "x", "profile" => "bogus"}
      })

    assert html =~ "unknown profile"

    # duplicates come back as a form error on submit
    seed = Application.get_env(:custode, :routines) |> hd() |> Map.fetch!(:id)

    html =
      render_submit(view, "new_agent_create", %{"routine" => %{"id" => seed}})

    assert html =~ "duplicate_id"
  end
end

defmodule CustodeWeb.FleetLiveFormStateTest do
  # Regression (operator-reported): changing one field must not clear the
  # others -- unbound inputs were wiped by the preview's re-render.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("formstate-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    workspace = tmp_workspace!()
    put_env!(:routines, [%{id: uid("seed"), cron: "@daily", workspace: workspace, prompt: "s"}])
    :ok
  end

  test "typed values survive a change that touches a different field" do
    {:ok, view, _html} = live(build_conn(), "/")
    render_click(view, "new_agent_open")

    # type an id first (the browser sends every field on each change; the id
    # rides along when the profile changes -- the bug was the RENDER dropping
    # it, so assert the rendered value attribute)
    render_change(view, "new_agent_change", %{"routine" => %{"id" => "sticky-id"}})

    html =
      render_change(view, "new_agent_change", %{
        "routine" => %{"id" => "sticky-id", "profile" => "backlog_worker"}
      })

    assert html =~ ~s(value="sticky-id")
    assert html =~ ~s(value="backlog_worker" selected)
    # and the preview reflects both fields together
    assert html =~ "id = &quot;sticky-id&quot;"
    assert html =~ "profile = &quot;backlog_worker&quot;"
  end
end
