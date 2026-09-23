defmodule Custode.DisownedTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]

  alias Custode.Disowned
  alias Custode.MCP.DisownTools

  @operator %Anubis.Server.Frame{}

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  setup do
    on_exit(fn -> Custode.Repo.query!("DELETE FROM disowned_prs") end)
    repo = "acme/" <> uid("disowned")
    owner = uid("owner")
    sibling = uid("sibling")
    foreign = uid("foreign")
    workspace = tmp_workspace!()
    foreign_repo = "acme/" <> uid("foreign-repo")

    put_env!(:routines, [
      %{id: owner, cron: :manual, workspace: workspace, prompt: "x", repo: repo},
      %{id: sibling, cron: :manual, workspace: workspace, prompt: "x", repo: repo},
      %{id: foreign, cron: :manual, workspace: workspace, prompt: "x", repo: foreign_repo}
    ])

    :ok = Custode.Repository.ensure_served(repo, owner)
    :ok = Custode.Repository.ensure_served(foreign_repo, foreign)
    %{repo: repo, owner: owner, sibling: sibling, foreign: foreign}
  end

  describe "disown/4" do
    test "records the judgment and its author", %{repo: repo} do
      {:ok, row} = Disowned.disown("mdbook-lint", repo, 400, "human's LSP config fix")

      assert row.repo == repo
      assert row.number == 400
      assert row.agent_id == "mdbook-lint"
      assert row.reason == "human's LSP config fix"
    end

    test "is idempotent, and the FIRST judgment stands", %{repo: repo} do
      {:ok, first} = Disowned.disown("mdbook-lint", repo, 400, "not mine")
      {:ok, second} = Disowned.disown("someone-else", repo, 400, "also not mine")

      assert first.id == second.id
      # a second agent agreeing is not new information, so the original author
      # and reasoning survive
      assert Disowned.get(repo, 400).agent_id == "mdbook-lint"
    end

    test "different PRs in one repo are separate judgments", %{repo: repo} do
      {:ok, _a} = Disowned.disown("mdbook-lint", repo, 400)
      {:ok, _b} = Disowned.disown("mdbook-lint", repo, 429)

      assert Disowned.numbers(repo) == MapSet.new([400, 429])
    end

    test "the same number in different repos does not collide", %{repo: repo} do
      {:ok, _a} = Disowned.disown("mdbook-lint", repo, 400)
      {:ok, _b} = Disowned.disown("other", "acme/other", 400)

      assert Disowned.numbers(repo) == MapSet.new([400])
      assert Disowned.numbers("acme/other") == MapSet.new([400])
    end
  end

  describe "reclaim/2" do
    test "a judgment is revisable", %{repo: repo} do
      {:ok, _row} = Disowned.disown("mdbook-lint", repo, 400)
      assert :ok = Disowned.reclaim(repo, 400)

      assert Disowned.get(repo, 400) == nil
      assert Disowned.numbers(repo) == MapSet.new()
    end

    test "reclaiming what was never disowned says so", %{repo: repo} do
      assert {:error, :not_disowned} = Disowned.reclaim(repo, 999)
    end
  end

  describe "by_repo/0" do
    test "groups every repo's numbers into sets", %{repo: repo} do
      {:ok, _a} = Disowned.disown("mdbook-lint", repo, 400)
      {:ok, _b} = Disowned.disown("mdbook-lint", repo, 429)
      {:ok, _c} = Disowned.disown("other", "acme/other", 7)

      by_repo = Disowned.by_repo()

      assert by_repo[repo] == MapSet.new([400, 429])
      assert by_repo["acme/other"] == MapSet.new([7])
    end

    test "an empty table is an empty map" do
      assert Disowned.by_repo() == %{}
    end
  end

  describe "the MCP tools" do
    test "repo_disown_pr records the caller as the author", %{repo: repo, owner: owner} do
      json =
        DisownTools.DisownPr.execute(
          %{repo: repo, number: 400, reason: "human's LSP config fix"},
          routine_frame(owner)
        )
        |> Custode.TestHelpers.tool_json()

      assert json["disowned_by"] == owner
      assert json["number"] == 400
      assert json["note"] =~ "reaches the operator"
    end

    test "repo_reclaim_pr undoes it", %{repo: repo, owner: owner} do
      {:ok, _row} = Disowned.disown(owner, repo, 400)

      json =
        DisownTools.ReclaimPr.execute(%{repo: repo, number: 400}, routine_frame(owner))
        |> Custode.TestHelpers.tool_json()

      assert json["disowned"] == false
      assert Disowned.get(repo, 400) == nil
    end

    test "repo_reclaim_pr on an owned PR is a tool error, not a crash", %{
      repo: repo,
      owner: owner
    } do
      error =
        DisownTools.ReclaimPr.execute(%{repo: repo, number: 999}, routine_frame(owner))
        |> Custode.TestHelpers.tool_error()

      assert error =~ "was not disowned"
    end

    test "another routine cannot revise or reclaim the owner's record", %{
      repo: repo,
      owner: owner,
      sibling: sibling
    } do
      {:ok, row} = Disowned.disown(owner, repo, 400, "not mine")

      error =
        DisownTools.DisownPr.execute(
          %{repo: repo, number: 400, reason: "replace it"},
          routine_frame(sibling)
        )
        |> Custode.TestHelpers.tool_error()

      assert error =~ "record owned by #{owner}"

      error =
        DisownTools.ReclaimPr.execute(%{repo: repo, number: 400}, routine_frame(sibling))
        |> Custode.TestHelpers.tool_error()

      assert error =~ "record owned by #{owner}"
      assert Disowned.get(repo, 400).id == row.id
      assert Disowned.get(repo, 400).reason == "not mine"
    end

    test "the human operator can reclaim another caller's record", %{repo: repo, owner: owner} do
      {:ok, _row} = Disowned.disown(owner, repo, 400)

      assert %{"disowned" => false} =
               DisownTools.ReclaimPr.execute(%{repo: repo, number: 400}, @operator)
               |> Custode.TestHelpers.tool_json()

      assert Disowned.get(repo, 400) == nil
    end

    test "an unserved repository is refused before a fact is written", %{owner: owner} do
      repo = "acme/" <> uid("unserved")

      error =
        DisownTools.DisownPr.execute(%{repo: repo, number: 400}, routine_frame(owner))
        |> Custode.TestHelpers.tool_error()

      assert error =~ "is not served"
      assert Disowned.get(repo, 400) == nil
    end

    test "a routine cannot write facts for another served repository", %{
      repo: repo,
      foreign: foreign
    } do
      error =
        DisownTools.DisownPr.execute(%{repo: repo, number: 400}, routine_frame(foreign))
        |> Custode.TestHelpers.tool_error()

      assert error =~ "owns repository"
      assert Disowned.get(repo, 400) == nil
    end

    test "list_disowned reports them, and filters by repo", %{repo: repo} do
      {:ok, _a} = Disowned.disown("mdbook-lint", repo, 400, "not mine")
      {:ok, _b} = Disowned.disown("other", "acme/other", 7)

      all = DisownTools.ListDisowned.execute(%{}, @operator) |> Custode.TestHelpers.tool_json()
      assert length(all["disowned"]) == 2

      mine =
        DisownTools.ListDisowned.execute(%{repo: repo}, @operator)
        |> Custode.TestHelpers.tool_json()

      assert [%{"number" => 400, "reason" => "not mine"}] = mine["disowned"]
    end
  end
end
