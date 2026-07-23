defmodule Custode.HomeTest do
  # The custode home (#41 / design 001 slice 5): $CUSTODE_HOME roots every
  # relative runtime path; unset means cwd, the unchanged source-repo mode.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Config.Loader
  alias Custode.Home

  setup do
    on_exit(fn ->
      System.delete_env("CUSTODE_HOME")
      Application.delete_env(:custode, :mode)
    end)

    :ok
  end

  describe "the four dirs resolve by mode (#266)" do
    test "source mode (default): every dir is the cwd" do
      System.delete_env("CUSTODE_HOME")
      Application.delete_env(:custode, :mode)

      for dir <- [&Home.config_dir/0, &Home.data_dir/0, &Home.runtime_dir/0, &Home.cache_dir/0] do
        assert dir.() == File.cwd!()
      end
    end

    test "CUSTODE_HOME collapses every dir under it, even in binary mode" do
      home = Path.join(System.tmp_dir!(), uid("home"))
      System.put_env("CUSTODE_HOME", home)
      Application.put_env(:custode, :mode, :binary)

      for dir <- [&Home.config_dir/0, &Home.data_dir/0, &Home.runtime_dir/0, &Home.cache_dir/0] do
        assert dir.() == home
      end
    end

    test "binary mode: the XDG split, from env vars" do
      System.delete_env("CUSTODE_HOME")
      Application.put_env(:custode, :mode, :binary)

      System.put_env("XDG_CONFIG_HOME", "/x/config")
      System.put_env("XDG_DATA_HOME", "/x/data")
      System.put_env("XDG_CACHE_HOME", "/x/cache")
      System.put_env("XDG_RUNTIME_DIR", "/x/run")

      on_exit(fn ->
        for v <- ~w(XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR),
            do: System.delete_env(v)
      end)

      assert Home.config_dir() == "/x/config/custode"
      assert Home.data_dir() == "/x/data/custode"
      assert Home.cache_dir() == "/x/cache/custode"
      assert Home.runtime_dir() == "/x/run/custode"
    end

    test "binary mode: runtime falls back to cache when XDG_RUNTIME_DIR is unset" do
      System.delete_env("CUSTODE_HOME")
      System.delete_env("XDG_RUNTIME_DIR")
      System.put_env("XDG_CACHE_HOME", "/x/cache")
      Application.put_env(:custode, :mode, :binary)
      on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)

      assert Home.runtime_dir() == "/x/cache/custode"
    end

    test "binary mode: XDG homes default to the ~ bases when unset" do
      System.delete_env("CUSTODE_HOME")

      for v <- ~w(XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME), do: System.delete_env(v)

      Application.put_env(:custode, :mode, :binary)

      assert Home.config_dir() == Path.join(System.user_home!(), ".config/custode")
      assert Home.data_dir() == Path.join(System.user_home!(), ".local/share/custode")
      assert Home.cache_dir() == Path.join(System.user_home!(), ".cache/custode")
    end
  end

  test "unset: the root is the cwd and relative paths resolve beneath it" do
    System.delete_env("CUSTODE_HOME")

    assert Home.root() == File.cwd!()
    assert Home.resolve("custode.db") == Path.join(File.cwd!(), "custode.db")
  end

  test "set: relative paths root under the home; absolute paths are respected" do
    home = Path.join(System.tmp_dir!(), uid("home"))
    System.put_env("CUSTODE_HOME", home)

    assert Home.root() == home
    assert Home.resolve("custode.db") == Path.join(home, "custode.db")
    assert Home.resolve("workspaces/x") == Path.join(home, "workspaces/x")
    # an absolute working_dir in the roster means what it says
    assert Home.resolve("/Users/x/code/repo") == "/Users/x/code/repo"
  end

  test "normalize roots relative workspaces under the home" do
    home = Path.join(System.tmp_dir!(), uid("home"))
    System.put_env("CUSTODE_HOME", home)
    id = uid("homed")

    put_env!(:routines, [%{id: id, cron: "@daily", prompt: "sweep"}])

    routine = Custode.Routine.get(id)
    assert routine.workspace == Path.join(home, "workspaces/#{id}")
    assert routine.working_dir == routine.workspace

    # explicit absolute working_dir survives untouched
    put_env!(:routines, [
      %{id: id, cron: "@daily", prompt: "sweep", working_dir: "/tmp/somewhere"}
    ])

    assert Custode.Routine.get(id).working_dir == "/tmp/somewhere"
  end

  test "the roster default path follows the home" do
    home = Path.join(System.tmp_dir!(), uid("home"))
    File.mkdir_p!(home)
    System.put_env("CUSTODE_HOME", home)

    roster = Path.join(home, "routines.toml")

    File.write!(roster, """
    [[routines]]
    id = "homedworker"
    cron = "@daily"
    prompt = "sweep"
    """)

    assert {:ok, ^roster, [entry], [], _} = Loader.load()
    assert entry.id == "homedworker"
  after
    File.rm(Path.join(Home.root(), "routines.toml"))
  end

  test "the four dirs collapse to CUSTODE_HOME when set, and cwd in source mode" do
    System.delete_env("CUSTODE_HOME")

    assert Enum.uniq([Home.config_dir(), Home.data_dir(), Home.runtime_dir(), Home.cache_dir()]) ==
             [File.cwd!()]

    home = Path.join(System.tmp_dir!(), uid("home"))
    System.put_env("CUSTODE_HOME", home)

    assert Enum.uniq([Home.config_dir(), Home.data_dir(), Home.runtime_dir(), Home.cache_dir()]) ==
             [home]

    # resolve_in binds a path to a specific dir; absolute stays absolute
    assert Home.resolve_in(&Home.data_dir/0, "custode.db") == Path.join(home, "custode.db")
    assert Home.resolve_in(&Home.runtime_dir/0, "/abs/x") == "/abs/x"
  end

  test "resolve! creates the parent so first boot needs no manual mkdir" do
    home = Path.join(System.tmp_dir!(), uid("home"))
    System.put_env("CUSTODE_HOME", home)

    path = Home.resolve!("tmp/agent_x.json")
    assert File.dir?(Path.dirname(path))
  end
end
