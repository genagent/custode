defmodule Custode.DraftsTest do
  # The batch filing gate (#241, design/006 slice 1): draft many, gate once,
  # file exactly what the operator did not drop.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Drafts

  defmodule FakeOps do
    @behaviour Custode.Repository.OpsBehaviour

    def open_issue(owner, repo, attrs) do
      send(pid(), {:open_issue, owner, repo, attrs})

      case Application.get_env(:custode, :fake_issue_error) do
        nil -> {:ok, %{"number" => 7, "html_url" => "https://x/#{owner}/#{repo}/issues/7"}}
        message -> {:error, message}
      end
    end

    def open_pr(_owner, _repo, _attrs), do: {:ok, %{}}
    def comment(_owner, _repo, _number, _body), do: {:ok, %{}}
    def ready_pr(_owner, _repo, _number), do: {:ok, %{}}
    def merge_pr(_owner, _repo, _number, _merge_method), do: {:ok, %{}}
    def merge_pr_at_head(_owner, _repo, _number, _head_sha, _merge_method), do: {:ok, %{}}
    def review_state(_owner, _repo, _number), do: :unreviewed
    def list_issues(_owner, _repo, _opts), do: {:ok, []}
    def view_issue(_owner, _repo, number), do: {:ok, %{number: number}}
    def list_prs(_owner, _repo, _opts), do: {:ok, []}
    def view_pr(_owner, _repo, number), do: {:ok, %{number: number}}
    def pr_checks(_owner, _repo, number), do: {:ok, %{sha: "abc", checks: [], number: number}}
    def job_log_tail(_owner, _repo, _job_id), do: {:error, :unused}
    def pr_diff(_owner, _repo, _number), do: {:ok, %{files: []}}
    def review_snapshot(_owner, _repo, _number, _merge_method), do: {:error, :unused}

    defp pid, do: Application.fetch_env!(:custode, :repo_ops_test_pid)
  end

  setup do
    Application.put_env(:custode, :repo_ops_test_pid, self())
    Application.delete_env(:custode, :fake_issue_error)
    on_exit(fn -> Application.delete_env(:custode, :fake_issue_error) end)
    put_env!(:repo_ops, FakeOps)

    repo_name = "acme/" <> uid("served")
    workspace = tmp_workspace!()

    routine =
      routine_fixture!(workspace, %{repo: repo_name, tags: [:repo], role: :steward})

    put_env!(:policies, [
      %{id: :conventional_commits, applies: [tag: :repo], text: "conventional style"}
    ])

    start_supervised!(
      Supervisor.child_spec({Custode.Repository, %{name: repo_name, routine_id: routine.id}},
        id: :drafts_test_repo
      )
    )

    %{repo: repo_name, id: routine.id}
  end

  defp three(repo, id) do
    {:ok, batch} =
      Drafts.draft(id, repo, [
        %{title: "chore: bump deps", body: "cargo outdated tail", labels: ["upkeep"]},
        %{title: "fix: flaky pool test", body: "3 of 20 runs failed"},
        %{title: "docs: dead link in README", body: "404 on the badge"}
      ])

    batch
  end

  test "drafting writes rows and files nothing", %{repo: repo, id: id} do
    batch = three(repo, id)

    assert length(batch.entries) == 3
    assert batch.batch_id =~ "batch-"
    refute_receive {:open_issue, _owner, _repo, _attrs}, 50

    assert Enum.map(Drafts.entries(batch.batch_id), & &1.status) ==
             ["drafted", "drafted", "drafted"]
  end

  test "the operator drops one entry and only the rest file", %{repo: repo, id: id} do
    batch = three(repo, id)
    [_first, second, _third] = batch.entries

    {:ok, dropped} = Drafts.drop(second.id)
    assert dropped.status == "dropped"

    {:ok, result} = Drafts.file(id, batch.batch_id)

    assert result.dropped == ["fix: flaky pool test"]
    assert Enum.map(result.filed, & &1.title) == ["chore: bump deps", "docs: dead link in README"]
    assert result.failed == []

    assert_receive {:open_issue, "acme", _bare, %{title: "chore: bump deps", labels: ["upkeep"]}}
    assert_receive {:open_issue, "acme", _bare, %{title: "docs: dead link in README"}}
    refute_receive {:open_issue, _owner, _repo, %{title: "fix: flaky pool test"}}, 50

    assert Enum.map(Drafts.entries(batch.batch_id), & &1.status) ==
             ["filed", "dropped", "filed"]
  end

  test "a drop is reversible until the batch files", %{repo: repo, id: id} do
    batch = three(repo, id)
    [first | _rest] = batch.entries

    {:ok, _} = Drafts.drop(first.id)
    {:ok, restored} = Drafts.restore(first.id)
    assert restored.status == "drafted"

    {:ok, result} = Drafts.file(id, batch.batch_id)
    assert length(result.filed) == 3

    # once filed, a late click cannot rewrite what happened
    assert Drafts.drop(first.id) == {:error, :already_filed}
  end

  test "filing twice files nothing twice", %{repo: repo, id: id} do
    batch = three(repo, id)

    {:ok, first} = Drafts.file(id, batch.batch_id)
    assert length(first.filed) == 3

    {:ok, second} = Drafts.file(id, batch.batch_id)
    assert second.filed == []
    assert second.failed == []
  end

  test "a refused entry fails alone; the rest of the batch still files", %{repo: repo, id: id} do
    {:ok, batch} =
      Drafts.draft(id, repo, [
        %{title: "make the tests pass"},
        %{title: "chore: bump deps"}
      ])

    {:ok, result} = Drafts.file(id, batch.batch_id)

    assert [%{title: "make the tests pass", error: message}] = result.failed
    assert message =~ "policy conventional_commits"
    assert Enum.map(result.filed, & &1.title) == ["chore: bump deps"]

    assert Enum.map(Drafts.entries(batch.batch_id), & &1.status) == ["failed", "filed"]
  end

  test "pending_batch is what the page renders, and closes once filed", %{repo: repo, id: id} do
    assert Drafts.pending_batch(id) == nil

    batch = three(repo, id)
    assert Enum.map(Drafts.pending_batch(id), & &1.id) == Enum.map(batch.entries, & &1.id)

    {:ok, _} = Drafts.file(id, batch.batch_id)
    assert Drafts.pending_batch(id) == nil
  end

  test "another routine's batch is not yours to file", %{repo: repo, id: id} do
    batch = three(repo, id)

    assert Drafts.file("someone-else", batch.batch_id) == {:error, :not_yours}
    assert Drafts.file(id, "batch-nope") == {:error, :unknown_batch}
    refute_receive {:open_issue, _owner, _repo, _attrs}, 50
  end

  test "the batch refuses to be empty, oversized, or titleless", %{repo: repo, id: id} do
    assert Drafts.draft(id, repo, []) == {:error, :empty}
    assert Drafts.draft(id, repo, [%{body: "no title"}]) == {:error, :missing_title}

    too_many = for n <- 1..(Drafts.max_entries() + 1), do: %{title: "chore: finding #{n}"}
    assert Drafts.draft(id, repo, too_many) == {:error, :too_many}

    assert Drafts.draft(id, repo, [%{title: "chore: x", body: String.duplicate("x", 20_001)}]) ==
             {:error, :body_too_large}
  end

  describe "the MCP verbs" do
    alias Custode.MCP.RepoTools.DraftIssues
    alias Custode.MCP.RepoTools.FileDrafts

    defp frame_for(id),
      do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

    test "draft then file, with the drop in between", %{repo: repo, id: id} do
      json =
        tool_json(
          DraftIssues.execute(
            %{
              routine_id: id,
              repo: repo,
              issues: [
                %{title: "chore: bump deps", body: "the tail", labels: ["upkeep"]},
                %{title: "fix: flaky test", body: "3 of 20"}
              ]
            },
            frame_for(id)
          )
        )

      assert [%{"title" => "chore: bump deps", "labels" => ["upkeep"]}, second] = json["drafted"]
      refute_receive {:open_issue, _owner, _repo, _attrs}, 50

      {:ok, _} = Drafts.drop(second["id"])

      filed =
        tool_json(
          FileDrafts.execute(
            %{routine_id: id, batch_id: json["batch_id"]},
            frame_for(id)
          )
        )

      assert [%{"title" => "chore: bump deps"}] = filed["filed"]
      assert filed["dropped"] == ["fix: flaky test"]
    end

    test "a routine may not draft or file under another's name", %{repo: repo, id: id} do
      error =
        tool_error(
          DraftIssues.execute(
            %{routine_id: id, repo: repo, issues: [%{title: "chore: x"}]},
            frame_for("intruder")
          )
        )

      assert error =~ "may not write"

      batch = three(repo, id)

      assert tool_error(
               FileDrafts.execute(
                 %{routine_id: id, batch_id: batch.batch_id},
                 frame_for("intruder")
               )
             ) =~ "may not write"

      refute_receive {:open_issue, _owner, _repo, _attrs}, 50
    end

    test "the batch cap is a refusal the model can read", %{repo: repo, id: id} do
      too_many = for n <- 1..(Drafts.max_entries() + 1), do: %{title: "chore: finding #{n}"}

      assert tool_error(
               DraftIssues.execute(
                 %{routine_id: id, repo: repo, issues: too_many},
                 frame_for(id)
               )
             ) =~ "at most #{Drafts.max_entries()} per batch"
    end
  end

  test "labels survive the round trip", %{repo: repo, id: id} do
    {:ok, batch} =
      Drafts.draft(id, repo, [%{title: "chore: x", labels: ["upkeep", "needs, comma"]}])

    [row] = Drafts.entries(batch.batch_id)
    assert Drafts.labels(row) == ["upkeep", "needs, comma"]
  end
end
