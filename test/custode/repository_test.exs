defmodule Custode.RepositoryTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Repository
  alias Custode.Repository.Ops

  defmodule FakeOps do
    @behaviour Custode.Repository.OpsBehaviour
    def open_pr(owner, repo, attrs) do
      send(pid(), {:open_pr, owner, repo, attrs})
      {:ok, %{"number" => 101, "html_url" => "https://x/#{owner}/#{repo}/pull/101"}}
    end

    def open_issue(owner, repo, attrs) do
      send(pid(), {:open_issue, owner, repo, attrs})
      {:ok, %{"number" => 202, "html_url" => "https://x/#{owner}/#{repo}/issues/202"}}
    end

    def comment(owner, repo, number, body) do
      send(pid(), {:comment, owner, repo, number, body})
      {:ok, %{"html_url" => "https://x/c/1"}}
    end

    def ready_pr(owner, repo, number) do
      send(pid(), {:ready_pr, owner, repo, number})
      {:ok, %{"number" => number, "draft" => false}}
    end

    def merge_pr(owner, repo, number) do
      send(pid(), {:merge_pr, owner, repo, number})

      case Application.get_env(:custode, :fake_merge_error) do
        nil -> {:ok, %{"merged" => true, "merge_method" => "squash"}}
        reason -> {:error, reason}
      end
    end

    def merge_pr_at_head(owner, repo, number, head_sha) do
      send(pid(), {:merge_pr_at_head, owner, repo, number, head_sha})

      case Application.get_env(:custode, :fake_merge_error) do
        nil -> {:ok, %{"merged" => true, "sha" => "merge-sha"}}
        reason -> {:error, reason}
      end
    end

    def review_state(_owner, _repo, _number) do
      Application.get_env(:custode, :fake_review_state, :unreviewed)
    end

    def list_issues(owner, repo, opts) do
      send(pid(), {:list_issues, owner, repo, opts})
      {:ok, [%{number: 1, title: "an issue", state: "open"}]}
    end

    def view_issue(owner, repo, number) do
      send(pid(), {:view_issue, owner, repo, number})
      {:ok, %{number: number, title: "an issue", body: "body", comments: []}}
    end

    def list_prs(owner, repo, opts) do
      send(pid(), {:list_prs, owner, repo, opts})
      {:ok, [%{number: 9, title: "a pr", state: "open", draft: true}]}
    end

    def view_pr(owner, repo, number) do
      send(pid(), {:view_pr, owner, repo, number})
      {:ok, %{number: number, title: "a pr", draft: true, body: "body"}}
    end

    def pr_checks(owner, repo, number) do
      send(pid(), {:pr_checks, owner, repo, number})
      {:ok, %{sha: "abc", checks: [%{name: "test", status: "completed", conclusion: "success"}]}}
    end

    def job_log_tail(owner, repo, job_id) do
      send(pid(), {:job_log_tail, owner, repo, job_id})
      {:ok, "the failure"}
    end

    def pr_diff(owner, repo, number) do
      send(pid(), {:pr_diff, owner, repo, number})
      {:ok, %{files: [%{filename: "lib/x.ex", status: "modified", patch: "@@ -1 +1 @@"}]}}
    end

    def review_snapshot(owner, repo, number) do
      send(pid(), {:review_snapshot, owner, repo, number})

      {:ok,
       %{
         pull_request: %{number: number, head_sha: "abc", base_sha: "def"},
         reviews: [%{id: 11, state: "CHANGES_REQUESTED"}],
         comments: [%{id: 12, body: "please fix"}],
         checks: [%{id: 13, name: "test", conclusion: "failure"}]
       }}
    end

    defp pid, do: Application.fetch_env!(:custode, :repo_ops_test_pid)
  end

  setup do
    Application.put_env(:custode, :repo_ops_test_pid, self())
    put_env!(:repo_ops, FakeOps)

    repo_name = "acme/" <> uid("served")
    workspace = tmp_workspace!()

    routine =
      routine_fixture!(workspace, %{
        repo: repo_name,
        tags: [:repo],
        role: :backlog_worker
      })

    put_env!(:policies, [
      %{
        id: :conventional_commits,
        applies: [tag: :repo],
        text: "conventional style"
      },
      %{id: :draft_pr_first, applies: [tag: :repo], text: "draft first"},
      %{id: :merge, applies: [tag: :repo], value: :manual, text: "humans merge"}
    ])

    start_supervised!(
      Supervisor.child_spec({Repository, %{name: repo_name, routine_id: routine.id}},
        id: :test_repo_server
      )
    )

    %{repo: repo_name}
  end

  test "open_pr enforces conventional titles and forces draft", %{repo: repo} do
    assert {:error, message} = Repository.open_pr(repo, %{title: "add stuff", head: "b"})
    assert message =~ "policy conventional_commits"
    refute_receive {:open_pr, _owner, _repo, _attrs}, 50

    assert {:ok, pr} =
             Repository.open_pr(repo, %{
               title: "feat: add stuff",
               head: "feat/stuff",
               draft: false
             })

    assert pr["number"] == 101
    assert_receive {:open_pr, "acme", _bare, attrs}
    # caller said draft: false; policy says draft anyway
    assert attrs.draft == true
    assert attrs.base == "main"
  end

  test "open_issue enforces conventional titles and passes labels through", %{repo: repo} do
    assert {:error, message} = Repository.open_issue(repo, %{title: "do a thing"})
    assert message =~ "policy conventional_commits"
    refute_receive {:open_issue, _owner, _repo, _attrs}, 50

    assert {:ok, issue} =
             Repository.open_issue(repo, %{
               title: "feat: do a thing",
               body: "the details",
               labels: ["workable"]
             })

    assert issue["number"] == 202
    assert_receive {:open_issue, "acme", _bare, attrs}
    assert attrs.title == "feat: do a thing"
    assert attrs.body == "the details"
    assert attrs.labels == ["workable"]
  end

  test "open_issue omits labels when none are given", %{repo: repo} do
    assert {:ok, _issue} = Repository.open_issue(repo, %{title: "fix: a bug"})
    assert_receive {:open_issue, "acme", _bare, attrs}
    refute Map.has_key?(attrs, :labels)
  end

  test "merge_pr refuses with the policy named; nothing reaches GitHub", %{repo: repo} do
    assert {:error, message} = Repository.merge_pr(repo, 7)
    assert message =~ "policy merge: humans merge"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50
  end

  test "the review floor (#86): even without a merge policy, unreviewed PRs cannot merge",
       %{repo: repo} do
    # drop the merge: :manual rule so only the workflow floor stands
    put_env!(:policies, [])
    put_env!(:fake_review_state, :unreviewed)

    assert {:error, message} = Repository.merge_pr(repo, 7)
    assert message =~ "workflow review"
    assert message =~ "even just lgtm"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50

    # a needs-human verdict POSITIVELY blocks, quoting the reviewer
    put_env!(
      :fake_review_state,
      {:needs_human, "review: needs-human -- auth surface, human eyes please"}
    )

    assert {:error, blocked} = Repository.merge_pr(repo, 7)
    assert blocked =~ "flagged PR #7"
    assert blocked =~ "auth surface, human eyes please"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50

    # a later ok review opens the door
    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})
    assert {:ok, %{"merged" => true}} = Repository.merge_pr(repo, 7)
    assert_receive {:merge_pr, "acme", _bare, 7}
  end

  test "the gated seam preserves the review floor and pins the expected head", %{repo: repo} do
    put_env!(:fake_review_state, :unreviewed)

    assert {:error, message} = Repository.merge_pr_at_head(repo, 7, "head-7")
    assert message =~ "workflow review"
    refute_receive {:merge_pr_at_head, _owner, _repo, _number, _head}, 50

    put_env!(:fake_review_state, {:reviewed, "approving review"})

    assert {:ok, %{"merged" => true, "sha" => "merge-sha"}} =
             Repository.merge_pr_at_head(repo, 7, "head-7")

    assert_receive {:merge_pr_at_head, "acme", _bare, 7, "head-7"}
  end

  test "a policy-allowed merge records the chosen method on the feed entry", %{repo: repo} do
    put_env!(:policies, [])
    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})

    assert {:ok, %{"merged" => true, "merge_method" => "squash"}} =
             Repository.merge_pr(repo, 7)

    assert Enum.any?(
             Custode.Feed.tail(50),
             &(&1["event"] == "repo_verb" and &1["verb"] == "merge_pr" and
                 &1["repo"] == repo and &1["number"] == 7 and &1["merge_method"] == "squash")
           )
  end

  test "a repository allowing no merge method refuses with the policy named", %{repo: repo} do
    put_env!(:policies, [])
    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})
    put_env!(:fake_merge_error, :no_allowed_merge_method)

    assert {:error, message} = Repository.merge_pr(repo, 7)
    assert message =~ "policy merge_method: #{repo} allows no supported merge method"
    assert message =~ "(merge, squash, rebase); nothing was merged"
    refute message =~ "github:"

    assert {:error, gated} = Repository.merge_pr_at_head(repo, 7, "head-7")
    assert gated =~ "policy merge_method: #{repo} allows no supported merge method"

    refute Enum.any?(
             Custode.Feed.tail(50),
             &(&1["event"] == "repo_verb" and &1["repo"] == repo and
                 &1["verb"] in ["merge_pr", "merge_pr_at_head"])
           )
  end

  test "comment and ready_pr pass through", %{repo: repo} do
    assert {:ok, _comment} = Repository.comment(repo, 5, "looks right")
    assert_receive {:comment, "acme", _bare, 5, "looks right"}

    assert {:ok, _pr} = Repository.ready_pr(repo, 9)
    assert_receive {:ready_pr, "acme", _bare, 9}
  end

  test "workflow markers format the conventions mechanically (#86)", %{repo: repo} do
    {:ok, _c} = Repository.mark_issue_ready(repo, 12, "drop the vestigial bound")
    assert_receive {:comment, "acme", _bare, 12, "ready: drop the vestigial bound"}

    {:ok, _c} = Repository.mark_issue_blocked(repo, 13, "needs maintainer design input")
    assert_receive {:comment, "acme", _bare, 13, "blocked: needs maintainer design input"}

    {:ok, _c} = Repository.review_pr(repo, 14, "lgtm", "small and clean")
    assert_receive {:comment, "acme", _bare, 14, "review: lgtm -- small and clean"}

    {:ok, _c} = Repository.review_pr(repo, 15, "needs-human", "auth surface")
    assert_receive {:comment, "acme", _bare, 15, "review: needs-human -- auth surface"}
  end

  test "verbs feed the record", %{repo: repo} do
    {:ok, _comment} = Repository.comment(repo, 5, "note")

    assert Enum.any?(
             Custode.Feed.tail(50),
             &(&1["event"] == "repo_verb" and &1["summary"] =~ "comment on #{repo}")
           )
  end

  test "read verbs pass through, scoped to the bound repo (#129)", %{repo: repo} do
    assert {:ok, [%{number: 1}]} = Repository.list_issues(repo)
    assert_receive {:list_issues, "acme", _bare, %{}}

    # state carries through to the ops layer
    assert {:ok, _} = Repository.list_issues(repo, %{state: "closed"})
    assert_receive {:list_issues, "acme", _bare, %{state: "closed"}}

    assert {:ok, %{number: 12, comments: []}} = Repository.view_issue(repo, 12)
    assert_receive {:view_issue, "acme", _bare, 12}

    assert {:ok, [%{number: 9, draft: true}]} = Repository.list_prs(repo)
    assert_receive {:list_prs, "acme", _bare, %{}}

    assert {:ok, %{number: 9, draft: true}} = Repository.view_pr(repo, 9)
    assert_receive {:view_pr, "acme", _bare, 9}

    assert {:ok, %{checks: [%{conclusion: "success"}]}} = Repository.pr_checks(repo, 9)
    assert_receive {:pr_checks, "acme", _bare, 9}

    assert {:ok, "the failure"} = Repository.job_log_tail(repo, 91)
    assert_receive {:job_log_tail, "acme", _bare, 91}

    assert {:ok, %{files: [%{filename: "lib/x.ex"}]}} = Repository.pr_diff(repo, 9)
    assert_receive {:pr_diff, "acme", _bare, 9}

    assert {:ok, %{pull_request: %{head_sha: "abc"}, reviews: [%{id: 11}]}} =
             Repository.review_snapshot(repo, 9)

    assert_receive {:review_snapshot, "acme", _bare, 9}
  end

  test "failure tails strip terminal control codes and stay bounded" do
    log =
      Enum.map_join(1..20, "\n", fn line ->
        if line == 20, do: "\e[31mline #{line} failed\e[0m", else: "line #{line}"
      end)

    tail = Ops.failure_tail(log)

    refute tail =~ "line 8\n"
    assert tail =~ "line 9\n"
    assert tail =~ "line 20 failed"
    refute tail =~ "\e["
  end

  describe "merge_method/1" do
    test "prefers a merge commit when the repository allows it" do
      repository = %{
        "allow_merge_commit" => true,
        "allow_squash_merge" => true,
        "allow_rebase_merge" => true
      }

      assert {:ok, "merge"} = Ops.merge_method(repository)
    end

    test "falls back to squash when merge commits are disabled" do
      repository = %{
        "allow_merge_commit" => false,
        "allow_squash_merge" => true,
        "allow_rebase_merge" => true
      }

      assert {:ok, "squash"} = Ops.merge_method(repository)
    end

    test "falls back to rebase when it is the only method allowed" do
      repository = %{
        "allow_merge_commit" => false,
        "allow_squash_merge" => false,
        "allow_rebase_merge" => true
      }

      assert {:ok, "rebase"} = Ops.merge_method(repository)
    end

    test "refuses when every method is disabled" do
      repository = %{
        "allow_merge_commit" => false,
        "allow_squash_merge" => false,
        "allow_rebase_merge" => false
      }

      assert {:error, :no_allowed_merge_method} = Ops.merge_method(repository)
    end

    test "keeps the merge default when the flags are not visible to the token" do
      assert {:ok, "merge"} = Ops.merge_method(%{"id" => 1})
      assert {:ok, "merge"} = Ops.merge_method(%{"allow_merge_commit" => nil})
    end
  end

  test "reads do NOT record a feed entry (only writes do)", %{repo: repo} do
    {:ok, _} = Repository.list_issues(repo)
    {:ok, _} = Repository.view_pr(repo, 9)

    refute Enum.any?(
             Custode.Feed.tail(200),
             &(&1["event"] == "repo_verb" and &1["summary"] =~ ~r/list_issues|view_pr/)
           )
  end

  test "an unserved repo is refused outright" do
    assert {:error, message} = Repository.merge_pr("evil/other", 1)
    assert message =~ "not served"

    # reads are scoped the same way -- an unserved repo cannot be read
    assert {:error, unread} = Repository.list_issues("evil/other")
    assert unread =~ "not served"
  end

  test "served_repos derives uniquely from the routine config" do
    workspace = tmp_workspace!()
    repo = "acme/" <> uid("derive")

    put_env!(:routines, [
      %{id: uid("a"), cron: :manual, workspace: workspace, prompt: "x", repo: repo},
      %{id: uid("b"), cron: :manual, workspace: workspace, prompt: "x", repo: repo},
      %{id: uid("c"), cron: :manual, workspace: workspace, prompt: "x"}
    ])

    assert [%{name: ^repo}] = Repository.served_repos()
  end
end
