defmodule Custode.RepositoryTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.RepoTools
  alias Custode.Repository
  alias Custode.Repository.Ops

  @actor %{kind: :routine, id: "repository-test"}

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

    def merge_pr(owner, repo, number, preferred) do
      send(pid(), {:merge_pr, owner, repo, number})
      send(pid(), {:merge_pr_preferred, preferred})

      case Application.get_env(:custode, :fake_merge_error) do
        nil -> {:ok, %{"merged" => true, "merge_method" => "squash"}}
        reason -> {:error, reason}
      end
    end

    def merge_pr_at_head(owner, repo, number, head_sha, merge_method) do
      send(pid(), {:merge_pr_at_head, owner, repo, number, head_sha})
      send(pid(), {:merge_pr_at_head_method, merge_method})

      case Application.get_env(:custode, :fake_merge_error) do
        nil -> {:ok, %{"merged" => true, "sha" => "merge-sha", "merge_method" => merge_method}}
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

    def checks_for_ref(owner, repo, ref) do
      send(pid(), {:checks_for_ref, owner, repo, ref})

      {:ok,
       [
         %{
           name: "test",
           status: "completed",
           conclusion: "failure",
           started_at: "2026-09-24T17:16:01Z",
           completed_at: "2026-09-24T17:16:04Z"
         }
       ]}
    end

    def job_log_tail(owner, repo, job_id) do
      send(pid(), {:job_log_tail, owner, repo, job_id})
      {:ok, "the failure"}
    end

    def pr_diff(owner, repo, number) do
      send(pid(), {:pr_diff, owner, repo, number})
      {:ok, %{files: [%{filename: "lib/x.ex", status: "modified", patch: "@@ -1 +1 @@"}]}}
    end

    def review_snapshot(owner, repo, number, preferred) do
      send(pid(), {:review_snapshot, owner, repo, number})
      send(pid(), {:review_snapshot_preferred, preferred})

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

    %{repo: repo_name, routine: routine}
  end

  defp repo_open_pr(repo, attrs), do: Repository.open_pr(repo, attrs, @actor)
  defp repo_open_issue(repo, attrs), do: Repository.open_issue(repo, attrs, @actor)
  defp repo_comment(repo, number, body), do: Repository.comment(repo, number, body, @actor)
  defp repo_ready_pr(repo, number), do: Repository.ready_pr(repo, number, @actor)
  defp repo_merge_pr(repo, number), do: Repository.merge_pr(repo, number, @actor)

  defp repo_merge_pr_at_head(repo, number, head_sha, method),
    do: Repository.merge_pr_at_head(repo, number, head_sha, method, @actor)

  defp repo_mark_issue_ready(repo, number, plan),
    do: Repository.mark_issue_ready(repo, number, plan, @actor)

  defp repo_mark_issue_blocked(repo, number, reason),
    do: Repository.mark_issue_blocked(repo, number, reason, @actor)

  defp repo_review_pr(repo, number, verdict, body),
    do: Repository.review_pr(repo, number, verdict, body, @actor)

  test "open_pr enforces conventional titles and forces draft", %{repo: repo} do
    assert {:error, message} = repo_open_pr(repo, %{title: "add stuff", head: "b"})
    assert message =~ "policy conventional_commits"
    refute_receive {:open_pr, _owner, _repo, _attrs}, 50

    assert {:ok, pr} =
             repo_open_pr(repo, %{
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
    assert {:error, message} = repo_open_issue(repo, %{title: "do a thing"})
    assert message =~ "policy conventional_commits"
    refute_receive {:open_issue, _owner, _repo, _attrs}, 50

    assert {:ok, issue} =
             repo_open_issue(repo, %{
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
    assert {:ok, _issue} = repo_open_issue(repo, %{title: "fix: a bug"})
    assert_receive {:open_issue, "acme", _bare, attrs}
    refute Map.has_key?(attrs, :labels)
  end

  test "merge_pr refuses with the policy named; nothing reaches GitHub", %{repo: repo} do
    assert {:error, message} = repo_merge_pr(repo, 7)
    assert message =~ "policy merge: humans merge"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50
  end

  test "the review floor (#86): even without a merge policy, unreviewed PRs cannot merge",
       %{repo: repo} do
    # drop the merge: :manual rule so only the workflow floor stands
    put_env!(:policies, [])
    put_env!(:fake_review_state, :unreviewed)

    assert {:error, message} = repo_merge_pr(repo, 7)
    assert message =~ "workflow review"
    assert message =~ "even just lgtm"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50

    # a needs-human verdict POSITIVELY blocks, quoting the reviewer
    put_env!(
      :fake_review_state,
      {:needs_human, "review: needs-human -- auth surface, human eyes please"}
    )

    assert {:error, blocked} = repo_merge_pr(repo, 7)
    assert blocked =~ "flagged PR #7"
    assert blocked =~ "auth surface, human eyes please"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50

    # a later ok review opens the door
    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})
    assert {:ok, %{"merged" => true}} = repo_merge_pr(repo, 7)
    assert_receive {:merge_pr, "acme", _bare, 7}
  end

  test "the gated seam preserves the review floor and pins the expected head", %{repo: repo} do
    put_env!(:fake_review_state, :unreviewed)

    assert {:error, message} = repo_merge_pr_at_head(repo, 7, "head-7", "squash")
    assert message =~ "workflow review"
    refute_receive {:merge_pr_at_head, _owner, _repo, _number, _head}, 50

    put_env!(:fake_review_state, {:reviewed, "approving review"})

    assert {:ok, %{"merged" => true, "sha" => "merge-sha"}} =
             repo_merge_pr_at_head(repo, 7, "head-7", "squash")

    assert_receive {:merge_pr_at_head, "acme", _bare, 7, "head-7"}
  end

  test "a policy-allowed merge records the chosen method on the feed entry", %{repo: repo} do
    put_env!(:policies, [])
    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})

    assert {:ok, %{"merged" => true, "merge_method" => "squash"}} =
             repo_merge_pr(repo, 7)

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

    assert {:error, message} = repo_merge_pr(repo, 7)
    assert message =~ "policy merge_method: #{repo} allows no supported merge method"
    assert message =~ "(merge, squash, rebase); nothing was merged"
    refute message =~ "github:"

    assert {:error, gated} = repo_merge_pr_at_head(repo, 7, "head-7", "squash")
    assert gated =~ "policy merge_method: #{repo} allows no supported merge method"

    refute Enum.any?(
             Custode.Feed.tail(50),
             &(&1["event"] == "repo_verb" and &1["repo"] == repo and
                 &1["verb"] in ["merge_pr", "merge_pr_at_head"])
           )
  end

  test "a served repository's merge_method policy reaches the merge and snapshot seams",
       %{repo: repo} do
    put_env!(:policies, [
      %{id: :merge_method, applies: [repo: repo], value: :rebase, text: "rebase here"}
    ])

    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})

    assert {:ok, _merged} = repo_merge_pr(repo, 7)
    assert_receive {:merge_pr_preferred, "rebase"}

    assert {:ok, _snapshot} = Repository.review_snapshot(repo, 9)
    assert_receive {:review_snapshot_preferred, "rebase"}
  end

  test "without a binding merge_method policy the flag order decides", %{repo: repo} do
    put_env!(:policies, [
      %{id: :merge_method, applies: [repo: "acme/elsewhere"], value: "rebase", text: "x"}
    ])

    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})

    assert {:ok, _merged} = repo_merge_pr(repo, 7)
    assert_receive {:merge_pr_preferred, nil}

    assert {:ok, _snapshot} = Repository.review_snapshot(repo, 9)
    assert_receive {:review_snapshot_preferred, nil}
  end

  test "an invalid merge_method policy value is refused with the policy named", %{repo: repo} do
    put_env!(:policies, [
      %{id: :merge_method, applies: [repo: repo], value: "fast-forward", text: "x"}
    ])

    put_env!(:fake_review_state, {:reviewed, "review: lgtm"})

    assert {:error, message} = repo_merge_pr(repo, 7)
    assert message =~ "policy merge_method: \"fast-forward\" configured for #{repo}"
    refute_receive {:merge_pr, _owner, _repo, _number}, 50

    assert {:error, snapshot_refusal} = Repository.review_snapshot(repo, 9)
    assert snapshot_refusal =~ "policy merge_method"
  end

  test "the exact-head seam sends the pinned method and refuses one GitHub disallows",
       %{repo: repo} do
    put_env!(:policies, [])
    put_env!(:fake_review_state, {:reviewed, "approving review"})

    assert {:ok, %{"merge_method" => "rebase"}} =
             repo_merge_pr_at_head(repo, 7, "head-7", "rebase")

    assert_receive {:merge_pr_at_head_method, "rebase"}

    put_env!(:fake_merge_error, {:merge_method_not_allowed, "rebase"})
    assert {:error, message} = repo_merge_pr_at_head(repo, 7, "head-7", "rebase")
    assert message =~ "policy merge_method: #{repo} does not allow the rebase merge method"
    refute message =~ "github:"
  end

  test "the exact-head seam refuses a Gate that pinned no method", %{repo: repo} do
    put_env!(:policies, [])
    put_env!(:fake_review_state, {:reviewed, "approving review"})

    assert {:error, message} = repo_merge_pr_at_head(repo, 7, "head-7", nil)
    assert message =~ "policy merge_method: the merge Gate for PR #7"
    refute_receive {:merge_pr_at_head, _owner, _repo, _number, _head}, 50
  end

  test "comment and ready_pr pass through", %{repo: repo} do
    assert {:ok, _comment} = repo_comment(repo, 5, "looks right")
    assert_receive {:comment, "acme", _bare, 5, "looks right"}

    assert {:ok, _pr} = repo_ready_pr(repo, 9)
    assert_receive {:ready_pr, "acme", _bare, 9}
  end

  test "workflow markers format the conventions mechanically (#86)", %{repo: repo} do
    {:ok, _c} = repo_mark_issue_ready(repo, 12, "drop the vestigial bound")
    assert_receive {:comment, "acme", _bare, 12, "ready: drop the vestigial bound"}

    {:ok, _c} = repo_mark_issue_blocked(repo, 13, "needs maintainer design input")
    assert_receive {:comment, "acme", _bare, 13, "blocked: needs maintainer design input"}

    {:ok, _c} = repo_review_pr(repo, 14, "lgtm", "small and clean")
    assert_receive {:comment, "acme", _bare, 14, "review: lgtm -- small and clean"}

    {:ok, _c} = repo_review_pr(repo, 15, "needs-human", "auth surface")
    assert_receive {:comment, "acme", _bare, 15, "review: needs-human -- auth surface"}
  end

  test "verbs feed the record", %{repo: repo} do
    {:ok, _comment} = repo_comment(repo, 5, "note")

    assert Enum.any?(
             Custode.Feed.tail(50),
             &(&1["event"] == "repo_verb" and &1["agent"] == @actor.id and
                 &1["summary"] =~ "comment on #{repo}")
           )
  end

  test "two MCP callers sharing one repository keep their own feed attribution", %{
    repo: repo,
    routine: first
  } do
    [first_config] = Application.fetch_env!(:custode, :routines)
    second_id = uid("routine")
    put_env!(:routines, [first_config, Map.put(first_config, :id, second_id)])

    first_frame =
      %Custode.MCP.CallContext{assigns: %{custode_identity: %{kind: :routine, id: first.id}}}

    second_frame =
      %Custode.MCP.CallContext{assigns: %{custode_identity: %{kind: :routine, id: second_id}}}

    assert %{"number" => 41} =
             RepoTools.Comment.execute(
               %{repo: repo, number: 41, body: "from the first routine"},
               first_frame
             )
             |> tool_json()

    assert %{"number" => 42} =
             RepoTools.Comment.execute(
               %{repo: repo, number: 42, body: "from the second routine"},
               second_frame
             )
             |> tool_json()

    assert [%{"agent" => first_id, "number" => 41, "repo" => ^repo, "verb" => "comment"}] =
             Custode.Feed.recent_by_event("repo_verb", agent: first.id, limit: 1)

    assert first_id == first.id

    assert [%{"agent" => ^second_id, "number" => 42, "repo" => ^repo, "verb" => "comment"}] =
             Custode.Feed.recent_by_event("repo_verb", agent: second_id, limit: 1)
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

    assert {:ok, [%{conclusion: "failure", started_at: "2026-09-24T17:16:01Z"}]} =
             Repository.checks_for_ref(repo, "main-sha")

    assert_receive {:checks_for_ref, "acme", _bare, "main-sha"}

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

  describe "Custode.Policy.merge_method/1" do
    test "binds by repository and normalizes the value" do
      put_env!(:policies, [
        %{id: :merge_method, applies: [repo: "acme/one"], value: :squash, text: "squash one"},
        %{id: :merge_method, applies: [tag: :repo], value: "rebase", text: "tags do not bind"}
      ])

      assert {:ok, "squash"} = Custode.Policy.merge_method("acme/one")
      assert is_nil(Custode.Policy.merge_method("acme/two"))
    end

    test "a value outside merge, squash, rebase is an error" do
      put_env!(:policies, [%{id: :merge_method, applies: :all, value: "ff", text: "x"}])
      assert {:error, {:invalid_merge_method, "ff"}} = Custode.Policy.merge_method("acme/one")
    end
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

    test "a preferred method wins over the flag order when the repository allows it" do
      repository = %{
        "allow_merge_commit" => true,
        "allow_squash_merge" => true,
        "allow_rebase_merge" => true
      }

      assert {:ok, "rebase"} = Ops.merge_method(repository, "rebase")
    end

    test "a preferred method the repository disallows is refused, not replaced" do
      repository = %{
        "allow_merge_commit" => true,
        "allow_squash_merge" => false,
        "allow_rebase_merge" => true
      }

      assert {:error, {:merge_method_not_allowed, "squash"}} =
               Ops.merge_method(repository, "squash")
    end

    test "a preferred method is kept when the flags are not visible to the token" do
      assert {:ok, "squash"} = Ops.merge_method(%{"id" => 1}, "squash")
    end

    test "keeps the merge default when the flags are not visible to the token" do
      assert {:ok, "merge"} = Ops.merge_method(%{"id" => 1})
      assert {:ok, "merge"} = Ops.merge_method(%{"allow_merge_commit" => nil})
    end
  end

  describe "the merge method sent to GitHub" do
    @stub __MODULE__.GitHubStub
    @all_allowed %{
      "allow_merge_commit" => true,
      "allow_squash_merge" => true,
      "allow_rebase_merge" => true
    }
    @squash_only %{
      "allow_merge_commit" => false,
      "allow_squash_merge" => true,
      "allow_rebase_merge" => false
    }
    @none_allowed %{
      "allow_merge_commit" => false,
      "allow_squash_merge" => false,
      "allow_rebase_merge" => false
    }

    setup do
      previous_token = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "test-token")
      Application.put_env(:custode, :github_req_options, plug: {Req.Test, @stub})

      on_exit(fn ->
        Application.delete_env(:custode, :github_req_options)

        if previous_token,
          do: System.put_env("GITHUB_TOKEN", previous_token),
          else: System.delete_env("GITHUB_TOKEN")
      end)

      :ok
    end

    defp stub_github(flags) do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/o/r"} ->
            Req.Test.json(conn, Map.merge(%{"full_name" => "o/r"}, flags))

          {"PUT", "/repos/o/r/pulls/1/merge"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:merge_request, Jason.decode!(raw)})
            Req.Test.json(conn, %{"merged" => true, "sha" => "abc"})

          {"GET", "/repos/o/r/pulls/1"} ->
            Req.Test.json(conn, %{"number" => 1, "head" => %{"sha" => "abc"}})

          {"GET", "/repos/o/r/pulls/1/reviews"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/o/r/issues/1/comments"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/o/r/commits/abc/check-runs"} ->
            Req.Test.json(conn, %{"total_count" => 0, "check_runs" => []})
        end
      end)
    end

    test "merge_pr sends squash to a squash-only repository" do
      stub_github(@squash_only)

      assert {:ok, %{"merged" => true, "merge_method" => "squash"}} =
               Ops.merge_pr("o", "r", 1, nil)

      assert_received {:merge_request, %{"merge_method" => "squash"} = body}
      refute Map.has_key?(body, "sha")
    end

    test "merge_pr sends merge to a repository that allows every method" do
      stub_github(@all_allowed)

      assert {:ok, %{"merged" => true, "merge_method" => "merge"}} =
               Ops.merge_pr("o", "r", 1, nil)

      assert_received {:merge_request, %{"merge_method" => "merge"}}
    end

    test "merge_pr_at_head sends squash and the head sha to a squash-only repository" do
      stub_github(@squash_only)

      assert {:ok, %{"merged" => true, "merge_method" => "squash"}} =
               Ops.merge_pr_at_head("o", "r", 1, "deadbeef", "squash")

      assert_received {:merge_request, %{"merge_method" => "squash", "sha" => "deadbeef"}}
    end

    test "merge_pr sends a policy-preferred method the repository allows" do
      stub_github(@all_allowed)

      assert {:ok, %{"merge_method" => "rebase"}} = Ops.merge_pr("o", "r", 1, "rebase")
      assert_received {:merge_request, %{"merge_method" => "rebase"}}
    end

    test "merge_pr refuses a policy-preferred method the repository disallows" do
      stub_github(@squash_only)

      assert {:error, {:merge_method_not_allowed, "rebase"}} = Ops.merge_pr("o", "r", 1, "rebase")
      refute_received {:merge_request, _body}
    end

    test "merge_pr_at_head sends exactly the pinned method, not the flag-order choice" do
      stub_github(@all_allowed)

      assert {:ok, %{"merge_method" => "squash"}} =
               Ops.merge_pr_at_head("o", "r", 1, "deadbeef", "squash")

      assert_received {:merge_request, %{"merge_method" => "squash", "sha" => "deadbeef"}}
    end

    test "merge_pr_at_head refuses a pinned method the repository no longer allows" do
      stub_github(%{@all_allowed | "allow_rebase_merge" => false})

      assert {:error, {:merge_method_not_allowed, "rebase"}} =
               Ops.merge_pr_at_head("o", "r", 1, "deadbeef", "rebase")

      refute_received {:merge_request, _body}
    end

    test "review_snapshot pins the selected method and types a disallowed preference" do
      stub_github(@squash_only)

      assert {:ok, %{merge_method: "squash"}} = Ops.review_snapshot("o", "r", 1, nil)
      assert {:ok, %{merge_method: "squash"}} = Ops.review_snapshot("o", "r", 1, "squash")

      assert {:error, {:merge_method_not_allowed, "rebase"}} =
               Ops.review_snapshot("o", "r", 1, "rebase")
    end

    test "review_snapshot types a repository with no supported merge method" do
      stub_github(@none_allowed)
      assert {:error, :no_allowed_merge_method} = Ops.review_snapshot("o", "r", 1, nil)
    end

    test "merge_pr makes no merge request when every method is disabled" do
      stub_github(@none_allowed)

      assert {:error, :no_allowed_merge_method} = Ops.merge_pr("o", "r", 1, nil)
      refute_received {:merge_request, _body}
    end

    test "merge_pr_at_head makes no merge request when every method is disabled" do
      stub_github(@none_allowed)

      assert {:error, {:merge_method_not_allowed, "squash"}} =
               Ops.merge_pr_at_head("o", "r", 1, "deadbeef", "squash")

      refute_received {:merge_request, _body}
    end
  end

  describe "checks for an exact ref" do
    @checks_stub __MODULE__.ChecksGitHubStub

    setup do
      previous_token = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "test-token")
      Application.put_env(:custode, :github_req_options, plug: {Req.Test, @checks_stub})

      on_exit(fn ->
        Application.delete_env(:custode, :github_req_options)

        if previous_token,
          do: System.put_env("GITHUB_TOKEN", previous_token),
          else: System.delete_env("GITHUB_TOKEN")
      end)

      :ok
    end

    defp stub_ref_evidence(check_runs, statuses \\ %{"total_count" => 0, "statuses" => []}) do
      test_pid = self()

      Req.Test.stub(@checks_stub, fn conn ->
        case conn.request_path do
          "/repos/o/r/commits/deadbeef/check-runs" ->
            send(test_pid, {:check_run_query, conn.request_path, conn.query_params})
            Req.Test.json(conn, check_runs)

          "/repos/o/r/commits/deadbeef/status" ->
            send(test_pid, {:commit_status_query, conn.request_path, conn.query_params})
            Req.Test.json(conn, statuses)
        end
      end)
    end

    test "requests the latest complete page and preserves timing evidence" do
      stub_ref_evidence(%{
        "total_count" => 1,
        "check_runs" => [
          %{
            "id" => 71,
            "name" => "test",
            "status" => "completed",
            "conclusion" => "failure",
            "html_url" => "https://github.com/o/r/actions/runs/71",
            "started_at" => "2026-09-24T17:16:01Z",
            "completed_at" => "2026-09-24T17:16:04Z"
          }
        ]
      })

      assert {:ok,
              [
                %{
                  id: 71,
                  name: "test",
                  status: "completed",
                  conclusion: "failure",
                  started_at: "2026-09-24T17:16:01Z",
                  completed_at: "2026-09-24T17:16:04Z"
                }
              ]} = Ops.checks_for_ref("o", "r", "deadbeef")

      assert_received {:check_run_query, "/repos/o/r/commits/deadbeef/check-runs",
                       %{"filter" => "latest", "per_page" => "100"}}

      assert_received {:commit_status_query, "/repos/o/r/commits/deadbeef/status",
                       %{"per_page" => "100"}}
    end

    test "refuses an incomplete first page instead of classifying partial evidence" do
      stub_ref_evidence(%{"total_count" => 2, "check_runs" => [%{"id" => 71}]})

      assert {:error, {:incomplete_check_runs, 2, 1}} =
               Ops.checks_for_ref("o", "r", "deadbeef")
    end

    test "refuses malformed check-run responses" do
      stub_ref_evidence(%{"total_count" => 1})
      assert {:error, :malformed_check_runs} = Ops.checks_for_ref("o", "r", "deadbeef")

      stub_ref_evidence(%{"total_count" => 1, "check_runs" => ["not a check run"]})
      assert {:error, :malformed_check_runs} = Ops.checks_for_ref("o", "r", "deadbeef")
    end

    test "includes the latest legacy status contexts in the rollup evidence" do
      stub_ref_evidence(
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "id" => 71,
              "name" => "test",
              "status" => "completed",
              "conclusion" => "failure",
              "started_at" => "2026-09-24T17:16:01Z",
              "completed_at" => "2026-09-24T17:16:03Z"
            }
          ]
        },
        %{
          "total_count" => 1,
          "statuses" => [
            %{
              "id" => 91,
              "context" => "external/security",
              "state" => "failure",
              "target_url" => "https://ci.example/91"
            }
          ]
        }
      )

      assert {:ok, [check, status]} = Ops.checks_for_ref("o", "r", "deadbeef")
      assert %{name: "test", conclusion: "failure"} = check

      assert %{
               name: "external/security",
               conclusion: "failure",
               source: :commit_status,
               started_at: nil,
               completed_at: nil
             } = status
    end

    test "refuses incomplete or malformed legacy status evidence" do
      checks = %{"total_count" => 0, "check_runs" => []}

      stub_ref_evidence(checks, %{"total_count" => 2, "statuses" => [%{"context" => "a"}]})

      assert {:error, {:incomplete_commit_statuses, 2, 1}} =
               Ops.checks_for_ref("o", "r", "deadbeef")

      stub_ref_evidence(checks, %{"total_count" => 1, "statuses" => [%{"context" => "a"}]})

      assert {:error, :malformed_commit_statuses} =
               Ops.checks_for_ref("o", "r", "deadbeef")
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
    assert {:error, message} = repo_merge_pr("evil/other", 1)
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
