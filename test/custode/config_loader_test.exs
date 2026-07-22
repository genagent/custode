defmodule Custode.Config.LoaderTest do
  # The routines.toml loader (#41 / design 001 slice 1). parse!/2 is pure;
  # the file/env paths are exercised through tmp files and a scoped env var.
  use ExUnit.Case, async: false

  alias Custode.Config.Loader

  @toml """
  # the operator's roster -- comments are load-bearing here
  [[routines]]
  id = "redisctl"
  profile = "backlog_worker"
  repo = "redis/redisctl"
  working_dir = "/tmp/redisctl"
  tags = ["rust", "external"]

  [[routines]]
  id = "quakes"
  cron = "manual"
  workspace = "workspaces/quakes"
  prompt = "Report on the quakes note."
  daily_budget_usd = 5.0

  [[sensors]]
  id = "ci-redisctl"
  cron = "*/15 * * * *"
  module = "CiStatus"
  notify = "redisctl"
  [sensors.args]
  repo = "redis/redisctl"
  """

  test "parses assignments into the exs shape normalize/1 consumes" do
    {[worker, manual], [sensor]} = Loader.parse!(@toml)

    assert worker == %{
             id: "redisctl",
             profile: :backlog_worker,
             repo: "redis/redisctl",
             working_dir: "/tmp/redisctl",
             tags: [:rust, :external]
           }

    # "manual" is the one magic cron string; budgets ride through as numbers
    assert manual.cron == :manual
    assert manual.daily_budget_usd == 5.0

    # sensor module short names resolve against Custode.Sensors.*
    assert sensor.module == Custode.Sensors.CiStatus
    assert sensor.args == %{"repo" => "redis/redisctl"}
    assert sensor.cron == "*/15 * * * *"
  end

  test "a parsed worker entry survives Routine.normalize with the profile applied" do
    previous = Application.get_env(:custode, :routines)
    {[worker, _manual], _sensors} = Loader.parse!(@toml)

    try do
      # drive it through the real choke point: the profile supplies the loop
      Application.put_env(:custode, :routines, [worker])
      normalized = Custode.Routine.get("redisctl")
      assert normalized.role == :backlog_worker
      assert normalized.approved_args["worktree"] == "custode-redisctl"
      assert normalized.working_dir == "/tmp/redisctl"
    after
      Application.put_env(:custode, :routines, previous)
    end
  end

  test "an unknown key is a boot error, not a silent drop" do
    bad = """
    [[routines]]
    id = "x"
    cronn = "@daily"
    """

    assert_raise RuntimeError, ~r/unknown key "cronn"/, fn -> Loader.parse!(bad) end
  end

  test "an unknown sensor module fails loudly at parse time" do
    bad = """
    [[sensors]]
    id = "s"
    cron = "@daily"
    module = "NoSuchSensor"
    notify = "x"
    """

    assert_raise RuntimeError, ~r/unknown sensor module/, fn -> Loader.parse!(bad) end
  end

  test "load/0 resolves CUSTODE_CONFIG, and no_file without it" do
    path = Path.join(System.tmp_dir!(), "roster-#{System.unique_integer([:positive])}.toml")
    File.write!(path, @toml)

    System.put_env("CUSTODE_CONFIG", path)

    try do
      assert {:ok, ^path, [_, _], [_]} = Loader.load()
    after
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
    end

    # without the env var and no ./routines.toml, nothing loads (D1 fallback:
    # the exs roster serves) -- guard against a stray file in cwd
    refute File.exists?("routines.toml")
    assert Loader.load() == :no_file
  end
end
