defmodule Custode.Advisors.DrynessTest do
  # The dryness advisor (design/005 slice 4, #274): a dry board plus quiet
  # routines raises a launch gate, and every other shape stays silent.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Advisors.Dryness
  alias Custode.Feed
  alias Custode.Repo
  alias Custode.Repository
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run

  @workflow "backlog-sweep"

  defmodule FakeOps do
    @moduledoc false

    def list_issues(_owner, _repo, _opts) do
      case Application.get_env(:custode, :fake_issues, []) do
        :unreadable -> {:error, "gh: 503"}
        issues -> {:ok, issues}
      end
    end
  end

  setup do
    Repo.delete_all(Run.Row)
    Repo.delete_all(Feed.Entry)

    path = Path.join(System.tmp_dir!(), uid("dryness-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    put_env!(:repo_ops, FakeOps)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:custode, :fake_issues)
    end)

    :ok
  end

  # A served repo with one routine on it, plus its Repository server.
  defp served!(opts \\ []) do
    repo = "acme/" <> uid("board")
    workspace = tmp_workspace!()

    routine =
      routine_fixture!(workspace, %{
        repo: repo,
        cron: Keyword.get(opts, :cron, "@daily"),
        tags: [:repo],
        role: :backlog_worker
      })

    start_supervised!(
      Supervisor.child_spec({Repository, %{name: repo, routine_id: routine.id}},
        id: {:dryness_repo, repo}
      )
    )

    %{repo: repo, routine: routine.id}
  end

  defp issues(specs) do
    Application.put_env(
      :custode,
      :fake_issues,
      for {number, labels} <- specs do
        %{number: number, title: "issue #{number}", state: "open", labels: labels}
      end
    )
  end

  defp sweeps(routine_id, count) do
    for _i <- 1..count, do: Feed.record(%{event: "turn", agent: routine_id, summary: "nothing"})
  end

  test "a dry board plus quiet routines raises one launch gate, with the why" do
    %{repo: repo, routine: routine} = served!()
    issues([{1, ["workable"]}, {2, []}, {3, []}])
    sweeps(routine, 8)

    assert [signal] = Dryness.proposable()
    assert signal.repo == repo
    assert signal.board.workable == 1
    assert signal.board.open == 3

    assert :ok = Dryness.perform(%Oban.Job{})

    assert [gate] = Enum.filter(Launch.pending(), &(&1["repo"] == repo))
    assert gate["workflow"] == @workflow
    assert gate["why"] =~ "down to 1 open workable issue(s) of 3 open"
    assert gate["why"] =~ "no gate and no verb in 8 sweeps"
    assert gate["why"] =~ routine
  end

  test "a board with work left stays quiet" do
    %{routine: routine} = served!()
    issues(for n <- 1..5, do: {n, ["workable"]})
    sweeps(routine, 8)

    assert Dryness.proposable() == []
  end

  test "a routine that still yields is not idle, however dry the board" do
    %{routine: routine} = served!()
    issues([])
    sweeps(routine, 8)
    Feed.record(%{event: "needs_approval", agent: routine, action: "one thing"})

    assert Dryness.proposable() == []
  end

  test "too few sweeps is no evidence either way" do
    %{routine: routine} = served!()
    issues([])
    sweeps(routine, 2)

    assert Dryness.proposable() == []
  end

  test "an unreadable board is not a dry one" do
    %{routine: routine} = served!()
    Application.put_env(:custode, :fake_issues, :unreadable)
    sweeps(routine, 8)

    assert Dryness.observe() |> Enum.map(& &1.board) == [:error]
    assert Dryness.proposable() == []

    # and the lenient half keeps its old contract for the demand read
    assert Custode.Backlog.size(hd(Dryness.observe()).repo) == 0
  end

  test "a standing gate suppresses a second proposal" do
    %{repo: repo, routine: routine} = served!()
    issues([])
    sweeps(routine, 8)

    assert :ok = Dryness.perform(%Oban.Job{})
    assert [_gate] = Enum.filter(Launch.pending(), &(&1["repo"] == repo))

    assert Dryness.proposable() == []
    assert :ok = Dryness.perform(%Oban.Job{})
    assert length(Enum.filter(Launch.pending(), &(&1["repo"] == repo))) == 1
  end

  test "a rejection inside the window is the cooldown" do
    %{repo: repo, routine: routine} = served!()
    issues([])
    sweeps(routine, 8)

    assert [signal] = Dryness.proposable()
    {:ok, proposal} = Launch.propose(@workflow, signal.repo, why: "test")
    :ok = Launch.reject(proposal.id, "not now")

    # the gate is no longer standing, and the advisor still does not re-ask
    assert Enum.filter(Launch.pending(), &(&1["repo"] == repo)) == []
    assert Dryness.proposable() == []
  end

  test "a live run of the same workflow on the same repo suppresses the proposal" do
    %{repo: repo, routine: routine} = served!()
    issues([])
    sweeps(routine, 8)

    Run.start(uid("run"), @workflow, repo, :mine)

    assert Dryness.proposable() == []
  end
end
