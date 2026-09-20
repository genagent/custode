defmodule Custode.Sensors.CiStatusTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Sensor.Health
  alias Custode.Sensors.CiStatus
  alias Custode.Test.FakeGitHubFetcher

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    repo = "acme/" <> uid("ci")
    sensor_id = uid("ci-sensor")

    args = %{"sensor_id" => sensor_id, "notify" => routine.id, "repo" => repo}
    %{workspace: workspace, routine: routine, repo: repo, sensor_id: sensor_id, args: args}
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
      checks: checks
    }
  end

  defp perform!(args), do: CiStatus.perform(%Oban.Job{args: args})

  defp inbox_notes(workspace) do
    Path.wildcard(Path.join([workspace, "inbox", "sensor-*"]))
  end

  defp fake_branch!(repo, state, extra_prs \\ []) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})

    overview =
      FakeGitHubFetcher.overview(repo, %{
        open_prs: %{total: length(extra_prs), items: extra_prs},
        default_branch: %{
          name: "main",
          state: state,
          oid: "abc1234",
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

      assert Enum.any?(jobs_for("ObanClaude.Agent.Tick"), &(&1.args["agent_id"] == routine.id))
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

    # the funnel scheduled the beat
    assert Enum.any?(jobs_for("ObanClaude.Agent.Tick"), &(&1.args["agent_id"] == routine.id))
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
