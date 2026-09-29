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
    {[worker, manual], [sensor], _} = Loader.parse!(@toml)

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

  test "a routines-only file parses to an empty profile map (no [[profiles]] section)" do
    {_routines, _sensors, profiles} = Loader.parse!(@toml)
    assert profiles == %{}
  end

  test "a [[profiles]] section parses into the %{name => envelope} shape" do
    toml =
      @toml <>
        """

        [[profiles]]
        name = "steward"
        cron = "@daily"
        role = "steward"
        model = "sonnet"
        tags = ["repo", "upkeep"]
        sensors = ["ci"]
        [profiles.approved_args]
        permission_mode = "bypass_permissions"
        """

    {_routines, _sensors, profiles} = Loader.parse!(toml)
    assert profiles.steward.role == :steward
    assert profiles.steward.tags == [:repo, :upkeep]
    assert profiles.steward.sensors == [:ci]
    assert profiles.steward.approved_args == %{"permission_mode" => "bypass_permissions"}
  end

  test "provider parses for routines and profiles" do
    toml = """
    [[routines]]
    id = "reviewer"
    provider = "codex"
    cron = "manual"
    prompt = "review"

    [[profiles]]
    name = "codex-review"
    provider = "codex"
    """

    {[routine], _sensors, profiles} = Loader.parse!(toml)
    assert routine.provider == :codex
    assert profiles[:"codex-review"].provider == :codex
  end

  test "permission_broker parses only on a routine" do
    toml = """
    [[routines]]
    id = "managed"
    cron = "manual"
    prompt = "read"
    mcp = true
    permission_broker = "read_only"
    """

    {[routine], [], %{}} = Loader.parse!(toml)
    assert routine.permission_broker == :read_only

    profile = """
    [[profiles]]
    name = "managed"
    permission_broker = "read_only"
    """

    assert_raise RuntimeError, ~r/unknown key "permission_broker"/, fn ->
      Loader.parse!(profile)
    end
  end

  test "apply_profiles/1 leaves config profiles intact for a profile-less file (#236 regression)" do
    # the bug: a legacy routines.toml (routines only, no [[profiles]]) parsed
    # to %{} and, applied strictly, wiped every config.exs profile the running
    # routines inherit from -- crashing the boot with "key :prompt not found".
    previous = Application.get_env(:custode, :profiles)

    try do
      Application.put_env(:custode, :profiles, %{backlog_worker: %{role: :backlog_worker}})

      # a profile-less file must NOT override
      :ok = Loader.apply_profiles(%{})

      assert Application.get_env(:custode, :profiles) == %{
               backlog_worker: %{role: :backlog_worker}
             }

      # a file that DOES declare profiles wins outright (D1)
      Loader.apply_profiles(%{steward: %{role: :steward}})
      assert Application.get_env(:custode, :profiles) == %{steward: %{role: :steward}}
    after
      Application.put_env(:custode, :profiles, previous)
    end
  end

  test "a parsed worker entry survives Routine.normalize with the profile applied" do
    previous = Application.get_env(:custode, :routines)
    {[worker, _manual], _sensors, _} = Loader.parse!(@toml)

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

  test "system_prompt_file rides through the file as a PATH, resolved downstream (#19)" do
    # design 001 D2: the roster file carries assignments, never prompt bodies.
    # A file entry references orders by path and Routine.normalize/1 -- the one
    # choke point both roster sources funnel through -- composes charter + body.
    dir = Path.join(System.tmp_dir!(), "orders-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    orders = Path.join(dir, "orders.md")
    File.write!(orders, "## Your role: toml-grown\nDo the referenced thing.")
    on_exit(fn -> File.rm_rf!(dir) end)

    toml = """
    [[routines]]
    id = "by-reference"
    profile = "backlog_worker"
    repo = "acme/a"
    working_dir = "/tmp/by-reference"
    system_prompt_file = "#{orders}"
    """

    {[worker], [], _} = Loader.parse!(toml)

    # the loader keeps it a string path -- no read, no body in the roster
    assert worker.system_prompt_file == orders

    previous = Application.get_env(:custode, :routines)

    try do
      Application.put_env(:custode, :routines, [worker])
      normalized = Custode.Routine.get("by-reference")

      assert normalized.system_prompt =~ "## Charter"
      assert normalized.system_prompt =~ "Do the referenced thing."
      # the file body replaces the role's default orders, it does not append
      refute normalized.system_prompt =~ "## Your role: backlog worker"
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
      assert {:ok, ^path, [_, _], [_], _} = Loader.load()
    after
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
    end

    # without the env var and no roster in the HOME root, nothing loads (D1
    # fallback: the exs roster serves). The repo root now carries a REAL
    # routines.toml (the machine's first write-back, 2026-07-22), so scope
    # the no-file case to an empty CUSTODE_HOME instead of the cwd.
    empty_home = Path.join(System.tmp_dir!(), "no-roster-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_home)
    System.put_env("CUSTODE_HOME", empty_home)

    try do
      assert Loader.load() == :no_file
    after
      System.delete_env("CUSTODE_HOME")
    end
  end
end
