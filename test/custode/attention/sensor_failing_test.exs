defmodule Custode.Attention.SensorFailingTest do
  @moduledoc """
  The gatherer's half of #444: a sensor run that keeps failing, end to end,
  from `perform/1` to the owning agent's resolved signal.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Attention.Fleet
  alias Custode.Sensor.Health
  alias Custode.Sensors.CiStatus
  alias Custode.Test.FakeGitHubFetcher

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    repo = "acme/" <> uid("sensor-failing")
    sensor_id = uid("ci-failing")

    put_env!(:sensors, [
      %{
        id: sensor_id,
        cron: "*/15 * * * *",
        module: CiStatus,
        notify: routine.id,
        args: %{repo: repo}
      }
    ])

    # the streak outlives the test otherwise, under a sensor id nothing reuses
    on_exit(fn -> Health.record_success(sensor_id) end)

    args = %{"sensor_id" => sensor_id, "notify" => routine.id, "repo" => repo}
    %{routine: routine, repo: repo, sensor_id: sensor_id, args: args}
  end

  defp fetch_result!(repo, result) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, result))
  end

  defp run!(args), do: :ok = CiStatus.perform(%Oban.Job{args: args})

  defp signal(agent_id), do: Map.fetch!(Fleet.signals_by_id(), agent_id)

  test "the third consecutive failure raises a watching signal naming the sensor and the error",
       %{routine: routine, repo: repo, sensor_id: sensor_id, args: args} do
    fetch_result!(repo, {:error, "Resource protected by organization SAML enforcement"})

    run!(args)
    run!(args)
    refute signal(routine.id).kind == :sensor_failing

    run!(args)
    raised = signal(routine.id)

    assert raised.kind == :sensor_failing
    assert raised.group == :watching
    assert raised.headline =~ "#{sensor_id} has failed 3 runs"
    assert raised.headline =~ "SAML enforcement"
    assert %DateTime{} = raised.raised_at
    assert Enum.any?(Fleet.signals(), &(&1.subject == routine.id and &1.kind == :sensor_failing))
  end

  test "one success clears it", %{routine: routine, repo: repo, args: args} do
    fetch_result!(repo, {:error, :rate_limited})
    for _run <- 1..3, do: run!(args)
    assert signal(routine.id).kind == :sensor_failing

    fetch_result!(repo, {:ok, FakeGitHubFetcher.overview(repo)})
    run!(args)

    refute signal(routine.id).kind == :sensor_failing
  end

  test "the threshold is :sensor_failure_threshold", %{routine: routine, repo: repo, args: args} do
    put_env!(:sensor_failure_threshold, 1)
    fetch_result!(repo, {:error, :rate_limited})

    run!(args)

    assert signal(routine.id).kind == :sensor_failing
  end

  test "a streak left behind by a sensor no longer configured raises nothing",
       %{routine: routine, repo: repo, args: args} do
    fetch_result!(repo, {:error, :rate_limited})
    for _run <- 1..3, do: run!(args)

    # removed from config: it will never run again, so no success could clear it
    put_env!(:sensors, [])

    refute signal(routine.id).kind == :sensor_failing
  end

  test "a failing sensor whose agent left the roster still gets a row",
       %{repo: repo, sensor_id: sensor_id} do
    departed = uid("departed-agent")

    put_env!(:sensors, [
      %{id: sensor_id, cron: "@hourly", module: CiStatus, notify: departed, args: %{repo: repo}}
    ])

    fetch_result!(repo, {:error, :rate_limited})
    args = %{"sensor_id" => sensor_id, "notify" => departed, "repo" => repo}
    for _run <- 1..3, do: run!(args)

    assert signal(departed).kind == :sensor_failing
  end
end
