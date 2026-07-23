defmodule Custode.Config.CustodeTomlTest do
  # The custode.toml loader (#267 / design 003 slice 2): parse!/1 is pure;
  # the scalar sections convert to the exact config :custode shapes, unknown
  # keys/sections fail loudly, deferred sections are recognized but skipped.
  use ExUnit.Case, async: true

  alias Custode.Config.CustodeToml

  test "[fleet] converts to the flat config :custode keys" do
    toml = """
    [fleet]
    timezone = "America/New_York"
    model = "opus"
    max_budget_usd = 3.0
    daily_budget_usd = 40.0
    """

    kw = CustodeToml.parse!(toml)
    assert kw[:timezone] == "America/New_York"
    assert kw[:model] == "opus"
    assert kw[:max_budget_usd] == 3.0
    assert kw[:daily_budget_usd] == 40.0
  end

  test "[janitor] nests under :janitor" do
    toml = """
    [janitor]
    feed_days = 30
    subagent_ttl_s = 3600
    """

    kw = CustodeToml.parse!(toml)
    assert kw[:janitor][:feed_days] == 30
    assert kw[:janitor][:subagent_ttl_s] == 3600
  end

  test "sections combine into one config :custode keyword list" do
    toml = """
    [fleet]
    model = "haiku"

    [janitor]
    feed_days = 14
    """

    kw = CustodeToml.parse!(toml)
    assert kw[:model] == "haiku"
    assert kw[:janitor] == [feed_days: 14]
  end

  test "an unknown key fails loudly" do
    toml = """
    [fleet]
    modle = "opus"
    """

    assert_raise RuntimeError, ~r/unknown key "modle" in \[fleet\]/, fn ->
      CustodeToml.parse!(toml)
    end
  end

  test "an unknown section fails loudly" do
    toml = """
    [nonsense]
    x = 1
    """

    assert_raise RuntimeError, ~r/unknown \[nonsense\] section/, fn ->
      CustodeToml.parse!(toml)
    end
  end

  test "deferred sections are recognized but not applied (no raise, no keys)" do
    toml = """
    [server]
    dashboard_port = 4646

    [ambient]
    orders = [{ repo = "x/y" }]

    [fleet]
    model = "sonnet"
    """

    kw = CustodeToml.parse!(toml)
    # only the applied section contributes; server/ambient are skipped
    assert kw[:model] == "sonnet"
    refute Keyword.has_key?(kw, :dashboard_port)
    refute Keyword.has_key?(kw, :orders)
  end

  test "load/0 returns :no_file when no custode.toml is present" do
    # source mode + no file under the cwd config dir
    System.delete_env("CUSTODE_HOME")

    prev = Application.get_env(:custode, :mode)
    Application.delete_env(:custode, :mode)
    on_exit(fn -> Application.put_env(:custode, :mode, prev) end)

    # the repo cwd has no custode.toml
    refute File.exists?(Path.join(File.cwd!(), "custode.toml"))
    assert CustodeToml.load() == :no_file
  end
end
