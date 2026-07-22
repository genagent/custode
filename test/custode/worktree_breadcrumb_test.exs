defmodule Custode.WorktreeBreadcrumbTest do
  # The worktree tripwire (#90): breadcrumbs at run start and stop for any
  # turn carrying a worktree arg, through the real telemetry path with a
  # real tmp git worktree directory.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  setup do
    path = Path.join(System.tmp_dir!(), uid("brc-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    System.cmd("git", ["-C", dir, "init", "-q", "-b", "tripwire-branch"])
    File.write!(Path.join(dir, "f.txt"), "x")
    System.cmd("git", ["-C", dir, "add", "."])

    System.cmd("git", ["-C", dir, "commit", "-q", "-m", "seed"],
      env: [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@t"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@t"}
      ]
    )

    dir
  end

  test "start and stop breadcrumbs bracket an elevated turn with real git state" do
    agent = uid("brc")
    base = Path.join(System.tmp_dir!(), uid("wd"))
    worktree = init_repo!(Path.join([base, ".claude", "worktrees", "custode-#{agent}"]))

    {:ok, _} =
      ObanClaude.run(
        %{
          "prompt" => "approved work",
          "worktree" => "custode-#{agent}",
          "working_dir" => base
        },
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: ObanClaude.Testing.respond(ObanClaude.Testing.result(result: "done"))
      )

    entries =
      Custode.Feed.for_agent(agent)
      |> Enum.filter(&(&1["event"] == "worktree_state"))

    assert length(entries) == 2
    phases = entries |> Enum.map(& &1["phase"]) |> Enum.sort()
    assert phases == ["start", "stop"]

    for entry <- entries do
      assert entry["worktree"] == worktree
      assert entry["branch"] == "tripwire-branch"
      assert entry["sha"] =~ ~r/^[0-9a-f]{40}$/
    end
  end

  test "the breadcrumb counts uncommitted work in flight as +added/-removed (#211)" do
    agent = uid("brc-diff")
    base = Path.join(System.tmp_dir!(), uid("wd"))
    worktree = init_repo!(Path.join([base, ".claude", "worktrees", "custode-#{agent}"]))

    # dirty the tree: modify the tracked file and add an untracked one
    File.write!(Path.join(worktree, "f.txt"), "x\ny\nz\n")
    File.write!(Path.join(worktree, "new.txt"), "one\ntwo\n")

    {:ok, _} =
      ObanClaude.run(
        %{
          "prompt" => "approved work",
          "worktree" => "custode-#{agent}",
          "working_dir" => base
        },
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: ObanClaude.Testing.respond(ObanClaude.Testing.result(result: "done"))
      )

    [entry | _] =
      Custode.Feed.for_agent(agent) |> Enum.filter(&(&1["event"] == "worktree_state"))

    # tracked file grew from 1 line to 3 (+? -?); untracked new.txt adds its
    # lines; the point is a positive addition count and zero-or-more removals
    assert entry["added"] > 0
    assert is_integer(entry["removed"])
  end

  test "an absent worktree at start records absent, not a crash" do
    agent = uid("brc-none")

    {:ok, _} =
      ObanClaude.run(
        %{"prompt" => "x", "worktree" => "never-made", "working_dir" => "/tmp/nope-#{agent}"},
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: ObanClaude.Testing.respond(ObanClaude.Testing.result(result: "ok"))
      )

    [entry | _rest] =
      Custode.Feed.for_agent(agent) |> Enum.filter(&(&1["event"] == "worktree_state"))

    assert entry["sha"] == "absent"
  end

  test "ordinary turns leave no breadcrumbs" do
    agent = uid("brc-plain")

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "sweep"},
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: ObanClaude.Testing.respond(ObanClaude.Testing.result(result: "ok"))
      )

    assert Custode.Feed.for_agent(agent) |> Enum.filter(&(&1["event"] == "worktree_state")) == []
  end
end
