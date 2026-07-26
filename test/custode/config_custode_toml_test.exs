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

  test "[advisors] maps names to crons or false (#260)" do
    toml = """
    [advisors]
    cadence = "0 9 * * *"
    model = false
    retro = "@weekly"
    """

    kw = CustodeToml.parse!(toml)
    assert kw[:advisors][:cadence] == "0 9 * * *"
    assert kw[:advisors][:model] == false
    assert kw[:advisors][:retro] == "@weekly"
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

  test "[profiles] is still an unknown section (design 003 slice 3, #268)" do
    assert_raise RuntimeError, ~r/unknown \[profiles\] section/, fn ->
      CustodeToml.parse!("[profiles.backlog_worker]\ncron = \"@daily\"\n")
    end
  end

  describe "[server] (#65)" do
    test "dashboard_port lands as the endpoint's http port, not a key of its own" do
      kw = CustodeToml.parse!("[server]\ndashboard_port = 8080\n")

      assert kw[CustodeWeb.Endpoint] == [http: [port: 8080]]
      refute Keyword.has_key?(kw, :dashboard_port)
    end

    test "mcp_port converts to the flat :mcp_port key" do
      assert CustodeToml.parse!("[server]\nmcp_port = 6262\n")[:mcp_port] == 6262
    end

    test "[server.dashboard_auth] converts to the Plug.BasicAuth keyword shape" do
      toml = """
      [server]
      dashboard_port = 4646

      [server.dashboard_auth]
      username = "custode"
      password = "hunter2"
      """

      kw = CustodeToml.parse!(toml)
      assert kw[:dashboard_auth] == [username: "custode", password: "hunter2"]
      assert kw[CustodeWeb.Endpoint] == [http: [port: 4646]]
    end

    test "half a credential fails the boot rather than opening the dashboard" do
      toml = """
      [server.dashboard_auth]
      username = "custode"
      """

      assert_raise RuntimeError, ~r/needs both a username and a password/, fn ->
        CustodeToml.parse!(toml)
      end
    end

    test "an unknown dashboard_auth key fails loudly" do
      toml = """
      [server.dashboard_auth]
      username = "custode"
      password = "hunter2"
      realm = "custode"
      """

      assert_raise RuntimeError, ~r/unknown key\(s\) \["realm"\]/, fn ->
        CustodeToml.parse!(toml)
      end
    end

    test "a port outside 1..65535 fails loudly" do
      assert_raise RuntimeError, ~r/dashboard_port in \[server\] must be a port/, fn ->
        CustodeToml.parse!("[server]\ndashboard_port = 99999\n")
      end
    end

    test "a non-integer port fails loudly" do
      assert_raise RuntimeError, ~r/mcp_port in \[server\] must be a port/, fn ->
        CustodeToml.parse!(~s([server]\nmcp_port = "6161"\n))
      end
    end

    test "an unknown [server] key fails loudly" do
      assert_raise RuntimeError, ~r/unknown key "dashbord_port" in \[server\]/, fn ->
        CustodeToml.parse!("[server]\ndashbord_port = 4646\n")
      end
    end
  end

  describe "dashboard_port/2" do
    test "reads the port the parsed config carries" do
      kw = CustodeToml.parse!("[server]\ndashboard_port = 8080\n")
      assert CustodeToml.dashboard_port(kw, 4646) == 8080
    end

    test "falls back to the default when [server] omits it" do
      kw = CustodeToml.parse!("[fleet]\nmodel = \"sonnet\"\n")
      assert CustodeToml.dashboard_port(kw, 4646) == 4646
      assert CustodeToml.dashboard_port([], 4646) == 4646
    end
  end

  describe "[ambient] (#19)" do
    test "single-key inline tables become Custode.Policy selectors" do
      toml = """
      [ambient]
      orders = [{ repo = "genagent/custode" }, { role = "backlog_worker" }, { tag = "dogfood" }]
      """

      kw = CustodeToml.parse!(toml)

      assert kw[:ambient_orders] == [
               repo: "genagent/custode",
               role: :backlog_worker,
               tag: :dogfood
             ]
    end

    # The conversion is only right if Custode.Policy accepts what it produces
    # -- the role/tag atoms in particular, which a string would silently fail
    # to match.
    test "the converted selectors drive Custode.Policy.applies?/2" do
      toml = ~s([ambient]\norders = [{ repo = "genagent/custode" }, { role = "reviewer" }]\n)
      selectors = CustodeToml.parse!(toml)[:ambient_orders]

      worker = %{repo: "genagent/custode", role: :backlog_worker, tags: []}
      reviewer = %{repo: "someone/else", role: :reviewer, tags: []}
      neither = %{repo: "someone/else", role: :backlog_worker, tags: []}

      assert Custode.Policy.applies?(selectors, worker)
      assert Custode.Policy.applies?(selectors, reviewer)
      refute Custode.Policy.applies?(selectors, neither)
    end

    test ~s(orders = "all" is the :all selector) do
      assert CustodeToml.parse!(~s([ambient]\norders = "all"\n))[:ambient_orders] == :all
    end

    test "an empty list is the default off" do
      assert CustodeToml.parse!("[ambient]\norders = []\n")[:ambient_orders] == []
    end

    test "a two-key selector fails loudly rather than widening the opt-in" do
      toml = ~s([ambient]\norders = [{ repo = "x/y", role = "reviewer" }]\n)

      assert_raise RuntimeError, ~r/takes exactly one key/, fn ->
        CustodeToml.parse!(toml)
      end
    end

    test "an unknown selector fails loudly" do
      assert_raise RuntimeError, ~r/unknown selector "owner"/, fn ->
        CustodeToml.parse!(~s([ambient]\norders = [{ owner = "x" }]\n))
      end
    end

    test "a non-string selector value fails loudly" do
      assert_raise RuntimeError, ~r/repo in \[ambient\] orders must be a string/, fn ->
        CustodeToml.parse!("[ambient]\norders = [{ repo = 42 }]\n")
      end
    end

    test "orders that is neither \"all\" nor a list fails loudly" do
      assert_raise RuntimeError, ~r/must be "all" or a list of selectors/, fn ->
        CustodeToml.parse!("[ambient]\norders = true\n")
      end
    end

    test "an unknown [ambient] key fails loudly" do
      assert_raise RuntimeError, ~r/unknown key "order" in \[ambient\]/, fn ->
        CustodeToml.parse!(~s([ambient]\norder = "all"\n))
      end
    end
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
