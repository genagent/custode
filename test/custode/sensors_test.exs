defmodule Custode.SensorsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Sensor.Health
  alias Custode.Sensors.ContributorSearch
  alias Custode.Sensors.GhRunner

  doctest Custode.Sensors.GhRunner

  setup do
    path = Path.join(System.tmp_dir!(), uid("sensor-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    put_env!(:gh_runner, Custode.Test.FakeGhRunner)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{workspace: workspace, routine: routine}
  end

  defp gh_item(repo, number, author, title \\ "a title") do
    %{
      "repository" => %{"nameWithOwner" => repo},
      "number" => number,
      "author" => %{"login" => author},
      "title" => title
    }
  end

  defp run_sensor!(routine) do
    sensor_id = "cs-" <> routine.id

    :ok =
      ContributorSearch.perform(%Oban.Job{
        args: %{"sensor_id" => sensor_id, "notify" => routine.id}
      })

    sensor_id
  end

  defp wake_jobs_for(routine_id) do
    jobs_for("Custode.InboxWakeJob")
    |> Enum.filter(
      &(&1.args["routine_id"] == routine_id and
          &1.state in ~w(available scheduled retryable executing))
    )
  end

  test "first run baselines silently; new items drop one note and retain one wake",
       %{workspace: workspace, routine: routine} do
    put_env!(:fake_gh_results, %{
      "issues" => [gh_item("o/r", 1, "alice"), gh_item("o/r", 2, "dependabot[bot]")],
      "prs" => []
    })

    sensor_id = run_sensor!(routine)

    # baseline: bot filtered, alice remembered, no note and no wake
    assert [] == Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))
    {:ok, seen} = Custode.Memory.recall("sensor:" <> sensor_id, "seen")
    assert Jason.decode!(seen) == ["o/r#1"]
    assert Custode.InboxWakes.get(routine.id) == nil
    assert wake_jobs_for(routine.id) == []

    # second run with one genuinely new item
    put_env!(:fake_gh_results, %{
      "issues" => [gh_item("o/r", 1, "alice"), gh_item("o/r", 7, "bob", "new thing")],
      "prs" => []
    })

    run_sensor!(routine)

    [note] = Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))
    content = File.read!(note)
    assert content =~ "o/r#7 by bob: new thing"
    refute content =~ "o/r#1"

    assert %{wake_id: wake_id, note_count: 1, blocked_by: "debounce"} =
             Custode.InboxWakes.get(routine.id)

    assert [%{args: %{"wake_id" => ^wake_id}}] = wake_jobs_for(routine.id)

    # third run: same world, nothing new, no second note or wake
    run_sensor!(routine)
    assert [_one] = Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))
    assert %{wake_id: ^wake_id, note_count: 1} = Custode.InboxWakes.get(routine.id)
    assert [%{args: %{"wake_id" => ^wake_id}}] = wake_jobs_for(routine.id)
  end

  test "closed items age out of the seen set", %{routine: routine} do
    put_env!(:fake_gh_results, %{"issues" => [gh_item("o/r", 1, "alice")], "prs" => []})
    sensor_id = run_sensor!(routine)

    put_env!(:fake_gh_results, %{"issues" => [], "prs" => []})
    run_sensor!(routine)

    {:ok, seen} = Custode.Memory.recall("sensor:" <> sensor_id, "seen")
    assert Jason.decode!(seen) == []
  end

  describe "a gh that fails (#479)" do
    # what a logged-out gh prints, after `Custode.Sensors.GhRunner` shortens it
    @logged_out "gh exited 4: To get started with GitHub CLI, please run:  gh auth login"

    defp seen(sensor_id) do
      {:ok, json} = Custode.Memory.recall("sensor:" <> sensor_id, "seen")
      json |> Jason.decode!() |> Enum.sort()
    end

    defp notes(workspace), do: Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))

    defp feed_events(agent_id, event) do
      agent_id |> Custode.Feed.for_agent(50) |> Enum.filter(&(&1["event"] == event))
    end

    test "is a fetch error, where it used to be an empty result" do
      put_env!(:fake_gh_results, %{"issues" => {:error, @logged_out}, "prs" => []})

      assert ContributorSearch.fetch(%{}) == {:error, @logged_out}
    end

    test "on one search out of the two still fails the whole fetch" do
      put_env!(:fake_gh_results, %{
        "issues" => [gh_item("o/r", 1, "alice")],
        "prs" => {:error, @logged_out}
      })

      # issues without PRs would replace the seen-set with half the world
      assert ContributorSearch.fetch(%{}) == {:error, @logged_out}
    end

    test "leaves the seen-set as it was and counts as a failed run",
         %{workspace: workspace, routine: routine} do
      put_env!(:fake_gh_results, %{
        "issues" => [gh_item("o/r", 1, "alice")],
        "prs" => [gh_item("o/r", 2, "bob")]
      })

      sensor_id = run_sensor!(routine)
      on_exit(fn -> Health.record_success(sensor_id) end)
      assert seen(sensor_id) == ["o/r#1", "o/r#2"]

      put_env!(:fake_gh_results, %{"issues" => {:error, @logged_out}, "prs" => []})
      run_sensor!(routine)

      assert seen(sensor_id) == ["o/r#1", "o/r#2"]
      assert notes(workspace) == []

      assert %{failures: 1, last_error: error} = Health.get(sensor_id)
      assert error =~ "gh exited 4"

      assert [failed] = feed_events(routine.id, "sensor_failed")
      assert failed["sensor_id"] == sensor_id
      assert failed["failures"] == 1
    end

    test "and then recovers does not note what it already knew",
         %{workspace: workspace, routine: routine} do
      known = %{
        "issues" => [gh_item("o/r", 1, "alice")],
        "prs" => [gh_item("o/r", 2, "bob")]
      }

      put_env!(:fake_gh_results, known)
      sensor_id = run_sensor!(routine)
      on_exit(fn -> Health.record_success(sensor_id) end)

      put_env!(:fake_gh_results, %{
        "issues" => {:error, @logged_out},
        "prs" => {:error, @logged_out}
      })

      run_sensor!(routine)
      run_sensor!(routine)
      assert %{failures: 2} = Health.get(sensor_id)

      # the same world comes back: nothing in it is news, and the streak ends
      put_env!(:fake_gh_results, known)
      run_sensor!(routine)

      assert notes(workspace) == []
      assert Health.get(sensor_id) == nil

      # something that appeared during the outage is the only new item
      put_env!(
        :fake_gh_results,
        Map.update!(known, "issues", &(&1 ++ [gh_item("o/r", 9, "carol")]))
      )

      run_sensor!(routine)

      assert [note] = notes(workspace)
      content = File.read!(note)
      assert content =~ "o/r#9 by carol"
      refute content =~ "o/r#1"
      refute content =~ "o/r#2"
    end
  end

  describe "the real gh runner (#479)" do
    test "a long failure is the exit code and the first line, clipped to 160 characters" do
      out = String.duplicate("x", 400) <> "\nUsage:  gh search issues [<query>] [flags]\n"

      reason = GhRunner.failure(1, out)

      assert String.starts_with?(reason, "gh exited 1: xxx")
      assert String.length(reason) == 160
      refute reason =~ "Usage"
    end

    test "leading blank lines are skipped" do
      assert GhRunner.failure(2, "\n  \nHTTP 403: SAML enforcement\nmore\n") ==
               "gh exited 2: HTTP 403: SAML enforcement"
    end

    # Runs `gh` for real, with a flag it refuses before it touches the
    # network. Where `gh` is not installed the same call exercises the
    # could-not-be-run path, and the contract is the same either way.
    test "a gh that fails, or is not there at all, is a short {:error, reason}" do
      assert {:error, reason} = GhRunner.run(["search", "issues", "--no-such-flag-custode-479"])

      assert reason =~ "gh "
      assert String.length(reason) <= 160
      refute reason =~ "\n"
    end
  end
end
