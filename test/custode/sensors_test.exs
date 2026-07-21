defmodule Custode.SensorsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Sensors.ContributorSearch

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

  test "first run baselines silently; new items drop ONE note and schedule a debounced beat",
       %{workspace: workspace, routine: routine} do
    put_env!(:fake_gh_results, %{
      "issues" => [gh_item("o/r", 1, "alice"), gh_item("o/r", 2, "dependabot[bot]")],
      "prs" => []
    })

    sensor_id = run_sensor!(routine)

    # baseline: bot filtered, alice remembered, NO note, NO beat
    assert [] == Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))
    {:ok, seen} = Custode.Memory.recall("sensor:" <> sensor_id, "seen")
    assert Jason.decode!(seen) == ["o/r#1"]

    assert jobs_for("ObanClaude.Agent.Tick") |> Enum.filter(&(&1.args["agent_id"] == routine.id)) ==
             []

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

    [beat] =
      jobs_for("ObanClaude.Agent.Tick") |> Enum.filter(&(&1.args["agent_id"] == routine.id))

    assert beat.state == "scheduled"

    # third run: same world, nothing new, no second note, no second beat
    run_sensor!(routine)
    assert [_one] = Path.wildcard(Path.join([workspace, "inbox", "sensor-*.md"]))

    assert [_one_beat] =
             jobs_for("ObanClaude.Agent.Tick")
             |> Enum.filter(&(&1.args["agent_id"] == routine.id))
  end

  test "closed items age out of the seen set", %{routine: routine} do
    put_env!(:fake_gh_results, %{"issues" => [gh_item("o/r", 1, "alice")], "prs" => []})
    sensor_id = run_sensor!(routine)

    put_env!(:fake_gh_results, %{"issues" => [], "prs" => []})
    run_sensor!(routine)

    {:ok, seen} = Custode.Memory.recall("sensor:" <> sensor_id, "seen")
    assert Jason.decode!(seen) == []
  end
end
