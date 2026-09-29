defmodule Custode.Sensors.CiStatusTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Attention.Fleet
  alias Custode.GitHub.Cache
  alias Custode.Repository
  alias Custode.Sensor.Health
  alias Custode.Sensors.CiStatus
  alias Custode.Sensors.CiStatus.Infrastructure
  alias Custode.Test.FakeGitHubFetcher

  defmodule FakeCheckOps do
    def checks_for_ref(_owner, _repo, ref) do
      :custode
      |> Application.get_env(:fake_ci_checks, %{})
      |> Map.get(ref, {:error, :not_faked})
    end
  end

  setup do
    workspace = tmp_workspace!()
    repo = "acme/" <> uid("ci")
    sensor_id = uid("ci-sensor")
    routine = routine_fixture!(workspace, %{repo: repo})

    put_env!(:repo_ops, FakeCheckOps)

    start_supervised!(
      Supervisor.child_spec({Repository, %{name: repo, routine_id: routine.id}},
        id: {:ci_status_repo, repo}
      )
    )

    put_env!(:sensors, [
      %{
        id: sensor_id,
        cron: "*/15 * * * *",
        module: CiStatus,
        notify: routine.id,
        args: %{repo: repo}
      }
    ])

    args = %{"sensor_id" => sensor_id, "notify" => routine.id, "repo" => repo}
    %{workspace: workspace, routine: routine, repo: repo, sensor_id: sensor_id, args: args}
  end

  defp checks!(by_ref), do: put_env!(:fake_ci_checks, by_ref)

  defp check(conclusion, elapsed_microseconds, extra \\ %{}) do
    started_at = ~U[2026-09-24 17:16:01.000000Z]

    Map.merge(
      %{
        name: "test",
        status: "completed",
        conclusion: conclusion,
        started_at: DateTime.to_iso8601(started_at),
        completed_at:
          started_at
          |> DateTime.add(elapsed_microseconds, :microsecond)
          |> DateTime.to_iso8601()
      },
      extra
    )
  end

  defp fake_prs!(repo, prs) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

    overview =
      FakeGitHubFetcher.overview(repo, %{open_prs: %{total: length(prs), items: prs}})

    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))
  end

  defp pr(number, checks) do
    %{
      number: number,
      title: "pr #{number}",
      url: "https://x/#{number}",
      draft: true,
      checks: checks,
      head_sha: "head-#{number}"
    }
  end

  defp perform!(args), do: CiStatus.perform(%Oban.Job{args: args})

  defp inbox_notes(workspace) do
    Path.wildcard(Path.join([workspace, "inbox", "sensor-*"]))
  end

  defp assert_pending_wake!(routine_id) do
    assert %{wake_id: wake_id, reason: "inbox_activity", blocked_by: "debounce"} =
             Custode.InboxWakes.get(routine_id)

    assert [job] =
             jobs_for("Custode.InboxWakeJob")
             |> Enum.filter(
               &(&1.args["routine_id"] == routine_id and
                   &1.state in ~w(available scheduled retryable executing))
             )

    assert job.args["wake_id"] == wake_id
  end

  defp fake_branch!(repo, state, extra_prs \\ [], oid \\ "abc1234") do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

    overview =
      FakeGitHubFetcher.overview(repo, %{
        open_prs: %{total: length(extra_prs), items: extra_prs},
        default_branch: %{
          name: "main",
          state: state,
          oid: oid,
          headline: "the merge that broke it"
        }
      })

    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))
  end

  describe "the default branch (#310)" do
    test "a red default branch drops a note that outranks the backlog",
         %{workspace: workspace, routine: routine, repo: repo, args: args} do
      fake_branch!(repo, "FAILURE")

      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      content = File.read!(note)

      assert content =~ "DEFAULT BRANCH"
      assert content =~ "main is red"
      assert content =~ "the merge that broke it"
      assert content =~ "outranks everything else"
      # it may not be the agent's to fix, and a duplicate fix is worse than none
      assert content =~ "duplicate fix is worse than none"

      assert_pending_wake!(routine.id)
    end

    test "a green default branch is not news", %{workspace: workspace, repo: repo, args: args} do
      fake_branch!(repo, "SUCCESS")
      :ok = perform!(args)
      assert inbox_notes(workspace) == []
    end

    test "an unreported rollup is not treated as red",
         %{workspace: workspace, repo: repo, args: args} do
      for state <- [nil, "PENDING"] do
        fake_branch!(repo, state)
        :ok = perform!(args)
        assert inbox_notes(workspace) == []
      end
    end

    test "a branch that stays red notes once; recovering and rebreaking notes again",
         %{workspace: workspace, repo: repo, args: args} do
      fake_branch!(repo, "FAILURE")
      :ok = perform!(args)
      assert [_note] = inbox_notes(workspace)

      # still red: keyed by NAME, so no second note for the same outage
      :ok = perform!(args)
      assert [_note] = inbox_notes(workspace)

      fake_branch!(repo, "SUCCESS")
      :ok = perform!(args)
      assert [_note] = inbox_notes(workspace)

      fake_branch!(repo, "FAILURE")
      :ok = perform!(args)
      assert [_first, _second] = inbox_notes(workspace)
    end

    test "a red branch and a red PR share one note, each with its own orders",
         %{workspace: workspace, repo: repo, args: args} do
      fake_branch!(repo, "FAILURE", [pr(9, "FAILURE")])

      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      content = File.read!(note)

      assert content =~ "main is red"
      assert content =~ "PR #9"
      # the PR half still points at disowning, which the branch half must not
      assert content =~ "repo_disown_pr"
    end
  end

  describe "infrastructure failures (#716)" do
    test "all ordinary failures at exactly five seconds are blocked without a note or wake",
         %{workspace: workspace, routine: routine, repo: repo, args: args} do
      fake_prs!(repo, [pr(9, "FAILURE")])

      checks!(%{
        "head-9" =>
          {:ok,
           [
             check("failure", 5_000_000),
             check("success", 40_000_000),
             %{status: "completed", conclusion: "success", source: :commit_status}
           ]}
      })

      :ok = perform!(args)

      assert inbox_notes(workspace) == []
      assert Custode.InboxWakes.get(routine.id) == nil

      assert %{
               ^repo => %{
                 repo: ^repo,
                 notify: notify,
                 prs: [9],
                 branches: [],
                 max_seconds: 5,
                 since: %DateTime{}
               }
             } = Infrastructure.active()

      assert notify == routine.id
    end

    test "a failure at five seconds plus one microsecond remains failing",
         %{workspace: workspace, repo: repo, args: args} do
      fake_prs!(repo, [pr(9, "FAILURE")])

      checks!(%{
        "head-9" => {:ok, [check("failure", 1_000_000), check("failure", 5_000_001)]}
      })

      :ok = perform!(args)

      assert [_note] = inbox_notes(workspace)
      assert Infrastructure.active() == %{}
    end

    test "the per-sensor bound overrides the application default",
         %{workspace: workspace, repo: repo, args: args} do
      put_env!(:ci_infrastructure_failure_seconds, 1)
      args = Map.put(args, "infrastructure_failure_seconds", 2)
      fake_prs!(repo, [pr(8, "FAILURE"), pr(9, "FAILURE")])

      checks!(%{
        "head-8" => {:ok, [check("failure", 2_000_000)]},
        "head-9" => {:ok, [check("failure", 2_000_001)]}
      })

      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      assert File.read!(note) =~ "PR #9"
      refute File.read!(note) =~ "PR #8"
      assert %{^repo => %{prs: [8], max_seconds: 2}} = Infrastructure.active()
    end

    test "every non-ordinary adverse conclusion keeps the rollup failing",
         %{workspace: workspace, repo: repo, args: args} do
      conclusions = ~w(action_required timed_out cancelled stale startup_failure future_outcome)

      prs =
        conclusions
        |> Enum.with_index(20)
        |> Enum.map(fn {_conclusion, number} -> pr(number, "FAILURE") end)

      runs =
        conclusions
        |> Enum.with_index(20)
        |> Map.new(fn {conclusion, number} ->
          {"head-#{number}", {:ok, [check("failure", 2_000_000), check(conclusion, 2_000_000)]}}
        end)

      fake_prs!(repo, prs)
      checks!(runs)

      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      content = File.read!(note)
      Enum.each(20..25, &assert(content =~ "PR ##{&1}"))
      assert Infrastructure.active() == %{}
    end

    test "empty runs, read errors, malformed runs and status contexts stay failing",
         %{workspace: workspace, repo: repo, args: args} do
      fake_prs!(repo, Enum.map(30..35, &pr(&1, "FAILURE")))

      checks!(%{
        "head-30" => {:ok, []},
        "head-31" => {:error, :rate_limited},
        "head-32" => {:ok, [check("failure", 1_000_000, %{started_at: "not-a-time"})]},
        "head-33" => {:ok, [check("failure", -1)]},
        "head-34" =>
          {:ok,
           [
             check("failure", 1_000_000),
             %{name: "external/security", conclusion: "failure", source: :commit_status}
           ]},
        "head-35" => {:ok, [check("failure", 1_000_000, %{status: "in_progress"})]}
      })

      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      content = File.read!(note)
      Enum.each(30..35, &assert(content =~ "PR ##{&1}"))
      assert Infrastructure.active() == %{}
    end

    test "a malformed item identity cannot disappear into infrastructure state",
         %{repo: repo, args: args} do
      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

      malformed =
        FakeGitHubFetcher.overview(repo, %{
          open_prs: %{
            total: 1,
            items: [
              %{
                number: nil,
                title: "missing number",
                url: "https://x/missing",
                draft: true,
                checks: "FAILURE",
                head_sha: "head-missing"
              }
            ]
          }
        })

      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, malformed}))
      checks!(%{"head-missing" => {:ok, [check("failure", 1_000_000)]}})

      assert {:ok, [%{number: nil}]} = CiStatus.fetch(args)
      assert Infrastructure.active() == %{}
    end

    test "the default branch uses the same classifier and recovers into a real failure",
         %{workspace: workspace, repo: repo, args: args} do
      fake_branch!(repo, "FAILURE")
      checks!(%{"abc1234" => {:ok, [check("failure", 2_000_000)]}})

      :ok = perform!(args)
      assert inbox_notes(workspace) == []
      assert %{^repo => %{prs: [], branches: ["main"]}} = Infrastructure.active()

      checks!(%{"abc1234" => {:ok, [check("failure", 5_000_001)]}})
      :ok = perform!(args)

      assert [note] = inbox_notes(workspace)
      assert File.read!(note) =~ "main is red"
      assert Infrastructure.active() == %{}
    end

    test "a total overview error retains evidence; a read error clears it and stays failing",
         %{workspace: workspace, repo: repo, args: args} do
      fake_prs!(repo, [pr(9, "FAILURE")])
      checks!(%{"head-9" => {:ok, [check("failure", 2_000_000)]}})
      :ok = perform!(args)
      assert %{^repo => %{prs: [9]}} = Infrastructure.active()

      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, :rate_limited}))
      :ok = perform!(args)
      assert %{^repo => %{prs: [9]}} = Infrastructure.active()

      fake_prs!(repo, [pr(9, "FAILURE")])
      checks!(%{"head-9" => {:error, :rate_limited}})
      :ok = perform!(args)

      assert [_note] = inbox_notes(workspace)
      assert Infrastructure.active() == %{}

      fake_prs!(repo, [pr(9, "SUCCESS")])
      :ok = perform!(args)
      assert Infrastructure.active() == %{}
    end

    test "one continuous repo condition keeps its first-seen time until recovery",
         %{repo: repo, args: args} do
      checks!(%{
        "head-1" => {:ok, [check("failure", 1_000_000)]},
        "head-2" => {:ok, [check("failure", 1_000_000)]}
      })

      fake_prs!(repo, [pr(1, "FAILURE")])
      :ok = perform!(args)
      first_since = Infrastructure.active()[repo].since

      Process.sleep(2)
      fake_prs!(repo, [pr(2, "FAILURE")])
      :ok = perform!(args)
      assert Infrastructure.active()[repo].since == first_since

      fake_prs!(repo, [pr(2, "SUCCESS")])
      :ok = perform!(args)
      assert Infrastructure.active() == %{}

      Process.sleep(2)
      fake_prs!(repo, [pr(2, "FAILURE")])
      :ok = perform!(args)
      assert DateTime.compare(Infrastructure.active()[repo].since, first_since) == :gt
    end

    test "an older duplicate observation cannot overwrite a newer clearing observation",
         %{routine: routine, repo: repo} do
      args = %{"sensor_id" => "older", "notify" => routine.id, "repo" => repo}
      older = DateTime.add(DateTime.utc_now(), -1, :second)
      newer = DateTime.utc_now()

      :ok =
        Infrastructure.replace(
          args,
          [%{kind: :pr, number: 9, head_sha: "head-9"}],
          5,
          older
        )

      assert %{^repo => %{prs: [9]}} = Infrastructure.active()

      :ok = Infrastructure.replace(args, [], 5, newer)
      assert Infrastructure.active() == %{}

      :ok =
        Infrastructure.replace(
          args,
          [%{kind: :pr, number: 9, head_sha: "head-9"}],
          5,
          older
        )

      assert Infrastructure.active() == %{}
    end

    test "the latest complete repo observation wins across duplicate sensors",
         %{routine: routine, repo: repo} do
      sensors = [
        %{
          id: "z-sensor",
          cron: "@hourly",
          module: CiStatus,
          notify: "z-owner",
          args: %{repo: repo}
        },
        %{
          id: "a-sensor",
          cron: "@hourly",
          module: CiStatus,
          notify: routine.id,
          args: %{repo: repo}
        }
      ]

      put_env!(:sensors, sensors)

      :ok =
        Infrastructure.replace(
          %{"sensor_id" => "z-sensor", "notify" => "z-owner", "repo" => repo},
          [
            %{kind: :pr, number: 4, head_sha: "head-4"},
            %{kind: :branch, name: "main", oid: "main-a"}
          ],
          7
        )

      :ok =
        Infrastructure.replace(
          %{"sensor_id" => "a-sensor", "notify" => routine.id, "repo" => repo},
          [
            %{kind: :pr, number: 3, head_sha: "head-3"},
            %{kind: :pr, number: 4, head_sha: "head-4"}
          ],
          5
        )

      assert %{
               ^repo => %{
                 sensor_id: "a-sensor",
                 notify: notify,
                 prs: [3, 4],
                 branches: [],
                 max_seconds: 5
               }
             } = Infrastructure.active()

      assert notify == routine.id

      :ok =
        Infrastructure.replace(
          %{"sensor_id" => "z-sensor", "notify" => "z-owner", "repo" => repo},
          [],
          7
        )

      assert Infrastructure.active() == %{}

      put_env!(:sensors, [])
      assert Infrastructure.active() == %{}
    end

    test "two routines sharing a repo produce one operator condition and no false red signals",
         %{routine: routine, repo: repo} do
      Custode.PubSubBridge.subscribe()
      clear_attention!()

      second_id = uid("ci-peer")

      put_env!(:routines, [
        %{
          id: routine.id,
          cron: "@daily",
          workspace: routine.workspace,
          prompt: "sweep now",
          repo: repo
        },
        %{
          id: second_id,
          cron: "@daily",
          workspace: tmp_workspace!(),
          prompt: "sweep now",
          repo: repo
        }
      ])

      put_env!(:sensors, [
        %{
          id: "ci-a",
          cron: "@hourly",
          module: CiStatus,
          notify: routine.id,
          args: %{repo: repo}
        },
        %{
          id: "ci-b",
          cron: "@hourly",
          module: CiStatus,
          notify: second_id,
          args: %{repo: repo}
        }
      ])

      args_a = %{"sensor_id" => "ci-a", "notify" => routine.id, "repo" => repo}
      args_b = %{"sensor_id" => "ci-b", "notify" => second_id, "repo" => repo}

      :ok =
        Infrastructure.replace(
          args_a,
          [
            %{kind: :pr, number: 9, head_sha: "head-9"},
            %{kind: :branch, name: "main", oid: "abc1234"}
          ],
          5
        )

      :ok =
        Infrastructure.replace(
          args_b,
          [
            %{kind: :pr, number: 9, head_sha: "head-9"},
            %{kind: :branch, name: "main", oid: "abc1234"}
          ],
          5
        )

      fake_branch!(repo, "FAILURE", [pr(9, "FAILURE")])
      Cache.forget(repo)
      on_exit(fn -> Cache.forget(repo) end)

      assert :loading = Custode.GitHub.overview(repo)
      assert_receive {:repo_overview, ^repo}, 2_000

      assert [condition] =
               Fleet.signals()
               |> Enum.filter(&(&1.kind == :ci_infrastructure and &1.subject == repo))

      assert {:ci_infrastructure, %{repo: ^repo, prs: [9], branches: ["main"]}} =
               condition.item

      views = Map.new(Fleet.views(), &{&1.id, &1})

      for id <- [routine.id, second_id] do
        assert views[id].failing_prs == []
        assert views[id].default_branch == nil
      end

      fake_branch!(repo, "FAILURE", [pr(9, "FAILURE") |> Map.put(:head_sha, "head-new")])

      Cache.forget(repo)
      assert :loading = Custode.GitHub.overview(repo)
      assert_receive {:repo_overview, ^repo}, 2_000

      assert [branch_only] =
               Fleet.signals()
               |> Enum.filter(&(&1.kind == :ci_infrastructure and &1.subject == repo))

      assert {:ci_infrastructure, %{repo: ^repo, prs: [], branches: ["main"]}} =
               branch_only.item

      partly_advanced = Map.new(Fleet.views(), &{&1.id, &1})

      for id <- [routine.id, second_id] do
        assert [%{number: 9}] = partly_advanced[id].failing_prs
        assert partly_advanced[id].default_branch == nil
      end

      fake_branch!(
        repo,
        "FAILURE",
        [pr(9, "FAILURE") |> Map.put(:head_sha, "head-new")],
        "main-new"
      )

      Cache.forget(repo)
      assert :loading = Custode.GitHub.overview(repo)
      assert_receive {:repo_overview, ^repo}, 2_000

      refute Enum.any?(Fleet.signals(), &(&1.kind == :ci_infrastructure and &1.subject == repo))

      advanced = Map.new(Fleet.views(), &{&1.id, &1})

      for id <- [routine.id, second_id] do
        assert [%{number: 9}] = advanced[id].failing_prs

        assert %{name: "main", state: "FAILURE", oid: "main-new"} =
                 advanced[id].default_branch
      end

      :ok = Infrastructure.replace(args_a, [], 5)

      refute Enum.any?(Fleet.signals(), &(&1.kind == :ci_infrastructure and &1.subject == repo))

      recovered = Map.new(Fleet.views(), &{&1.id, &1})

      for id <- [routine.id, second_id] do
        assert [%{number: 9}] = recovered[id].failing_prs
        assert %{name: "main", state: "FAILURE"} = recovered[id].default_branch
      end
    end

    test "missing overview refs do not suppress failures without matching evidence",
         %{routine: routine, repo: repo} do
      Custode.PubSubBridge.subscribe()
      clear_attention!()

      failing_pr = pr(9, "FAILURE") |> Map.put(:head_sha, nil)
      fake_branch!(repo, "FAILURE", [failing_pr], nil)
      Cache.forget(repo)
      on_exit(fn -> Cache.forget(repo) end)

      assert :loading = Custode.GitHub.overview(repo)
      assert_receive {:repo_overview, ^repo}, 2_000

      view = Enum.find(Fleet.views(), &(&1.id == routine.id))
      assert [%{number: 9}] = view.failing_prs
      assert %{name: "main", oid: nil, state: "FAILURE"} = view.default_branch
    end
  end

  test "a newly failing PR drops a note and fires the kickoff",
       %{workspace: workspace, routine: routine, repo: repo, args: args} do
    fake_prs!(repo, [pr(7, "SUCCESS"), pr(9, "FAILURE")])

    :ok = perform!(args)

    assert [note] = inbox_notes(workspace)
    content = File.read!(note)
    assert content =~ "PR #9"
    assert content =~ "FAILURE"
    assert content =~ repo
    refute content =~ "PR #7"

    assert_pending_wake!(routine.id)
  end

  test "a persistently failing PR notes once; breaking again notes again",
       %{workspace: workspace, repo: repo, args: args} do
    fake_prs!(repo, [pr(9, "FAILURE")])
    :ok = perform!(args)
    assert [_note] = inbox_notes(workspace)

    # still failing next poll: no new note
    :ok = perform!(args)
    assert [_note] = inbox_notes(workspace)

    # recovers, then breaks again: a fresh note
    fake_prs!(repo, [pr(9, "SUCCESS")])
    :ok = perform!(args)
    fake_prs!(repo, [pr(9, "ERROR")])
    :ok = perform!(args)
    assert [_first, _second] = inbox_notes(workspace)
  end

  test "a fetch error skips quietly and the next poll still works",
       %{workspace: workspace, repo: repo, args: args} do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, :rate_limited}))

    :ok = perform!(args)
    assert inbox_notes(workspace) == []

    fake_prs!(repo, [pr(3, "FAILURE")])
    :ok = perform!(args)
    assert [_note] = inbox_notes(workspace)
  end

  describe "a fetch that keeps failing (#444)" do
    defp fail!(repo, reason) do
      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, reason}))
    end

    defp feed_events(agent_id, event) do
      agent_id |> Custode.Feed.for_agent(50) |> Enum.filter(&(&1["event"] == event))
    end

    test "each failed run is a sensor_failed entry carrying the count and the error",
         %{routine: routine, repo: repo, sensor_id: sensor_id, args: args} do
      fail!(repo, "Resource protected by organization SAML enforcement")

      :ok = perform!(args)
      :ok = perform!(args)

      assert [first, second] = feed_events(routine.id, "sensor_failed")
      assert first["sensor_id"] == sensor_id
      assert first["failures"] == 1
      assert second["failures"] == 2
      assert second["error"] == "Resource protected by organization SAML enforcement"
      assert second["summary"] =~ "2 runs in a row"
      # nothing was fetched, so there is no grey "nothing new" line to hide behind
      assert feed_events(routine.id, "sensor") == []
    end

    test "only the run that reaches the threshold is marked as crossing it",
         %{routine: routine, repo: repo, args: args} do
      fail!(repo, :rate_limited)
      for _run <- 1..4, do: :ok = perform!(args)

      assert [false, false, true, false] ==
               routine.id |> feed_events("sensor_failed") |> Enum.map(& &1["crossed_threshold"])
    end

    test "one successful run resets the count",
         %{routine: routine, repo: repo, sensor_id: sensor_id, args: args} do
      fail!(repo, :rate_limited)
      :ok = perform!(args)
      :ok = perform!(args)
      assert %{failures: 2} = Health.get(sensor_id)

      fake_prs!(repo, [pr(1, "SUCCESS")])
      :ok = perform!(args)
      assert Health.get(sensor_id) == nil

      fail!(repo, :rate_limited)
      :ok = perform!(args)
      assert %{failures: 1} = Health.get(sensor_id)
      assert [_first, _second, third] = feed_events(routine.id, "sensor_failed")
      assert third["failures"] == 1
    end

    test "a failed run leaves the seen-set alone, so recovery does not re-note old items",
         %{workspace: workspace, repo: repo, args: args} do
      fake_prs!(repo, [pr(3, "FAILURE")])
      :ok = perform!(args)
      assert [_note] = inbox_notes(workspace)

      fail!(repo, :rate_limited)
      :ok = perform!(args)

      fake_prs!(repo, [pr(3, "FAILURE")])
      :ok = perform!(args)
      assert [_still_one] = inbox_notes(workspace)
    end
  end

  test "all-green is a quiet feed entry, no note", %{workspace: workspace, repo: repo, args: args} do
    fake_prs!(repo, [pr(1, "SUCCESS"), pr(2, nil)])
    :ok = perform!(args)
    assert inbox_notes(workspace) == []
  end

  test "the crontab carries the ci sensors" do
    put_env!(:sensors, [
      %{
        id: "ci-x",
        cron: "*/15 * * * *",
        module: CiStatus,
        notify: "x",
        args: %{repo: "a/b"}
      }
    ])

    assert {"*/15 * * * *", CiStatus, opts} =
             Enum.find(Custode.Routine.crontab(), &(elem(&1, 1) == CiStatus))

    assert opts[:queue] == :sensors
    # atom-keyed here; Oban's JSON round trip stringifies it for perform/1
    assert opts[:args][:repo] == "a/b"
    assert opts[:args]["notify"] == "x"
  end
end
