defmodule Custode.Sensors.UsgsQuakesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Routine.Prompts
  alias Custode.Sensors.UsgsQuakes

  defmodule FakeFetcher do
    def fetch(_url) do
      Application.get_env(:custode, :fake_quake_feed, {:error, :not_faked})
    end
  end

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{role: :quake_watch})
    put_env!(:quake_fetcher, FakeFetcher)

    args = %{
      "sensor_id" => uid("usgs"),
      "notify" => routine.id,
      "min_magnitude" => 4.5
    }

    %{workspace: workspace, routine: routine, args: args}
  end

  defp feature(id, magnitude, opts \\ []) do
    %{
      "id" => id,
      "properties" => %{
        "mag" => magnitude,
        "place" => opts[:place] || "somewhere",
        "time" => 1_784_658_807_762,
        "tsunami" => if(opts[:tsunami], do: 1, else: 0),
        "url" => "https://earthquake.usgs.gov/earthquakes/eventpage/#{id}"
      }
    }
  end

  defp fake!(features), do: put_env!(:fake_quake_feed, {:ok, %{"features" => features}})

  defp notes(workspace), do: Path.wildcard(Path.join([workspace, "inbox", "sensor-*"]))

  defp perform!(args), do: UsgsQuakes.perform(%Oban.Job{args: args})

  test "new events above threshold drop a note and wake the routine",
       %{workspace: workspace, routine: routine, args: args} do
    fake!([
      feature("q1", 5.1, place: "Kalbay, Philippines"),
      feature("q2", 3.9),
      feature("q3", 6.8, tsunami: true, place: "off Chile")
    ])

    :ok = perform!(args)

    assert [note] = notes(workspace)
    content = File.read!(note)
    assert content =~ "M6.8 off Chile"
    assert content =~ "TSUNAMI FLAG SET"
    assert content =~ "M5.1 Kalbay, Philippines"
    # below threshold: mechanically filtered, never wakes the brain
    refute content =~ "q2"

    assert Enum.any?(jobs_for("ObanClaude.Agent.Tick"), &(&1.args["agent_id"] == routine.id))
  end

  test "already-seen events never re-note; new ones do",
       %{workspace: workspace, args: args} do
    fake!([feature("q1", 5.0)])
    :ok = perform!(args)
    assert [_note] = notes(workspace)

    :ok = perform!(args)
    assert [_note] = notes(workspace)

    fake!([feature("q1", 5.0), feature("q4", 4.9)])
    :ok = perform!(args)
    # filename suffixes are unique_integers, so order is not lexicographic;
    # find the fresh note by content
    assert [_first, _second] = notes(workspace)
    assert Enum.any?(notes(workspace), &(File.read!(&1) =~ "q4"))
  end

  test "a fetch error skips quietly", %{workspace: workspace, args: args} do
    put_env!(:fake_quake_feed, {:error, :timeout})
    :ok = perform!(args)
    assert notes(workspace) == []
  end

  test "the quake_watch role composes with the charter" do
    prompt = Prompts.for_role(:quake_watch, "quakes")
    assert prompt =~ "## Charter"
    assert prompt =~ "earthquake watch"
    assert prompt =~ "M6.5+"
    assert prompt =~ "never fetch feeds yourself"
  end
end
