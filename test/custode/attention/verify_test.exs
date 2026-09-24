defmodule Custode.Attention.VerifyTest do
  @moduledoc """
  The two-tier read (#317): the cached signal decides `:watching`, and
  promotion to `:needs_you` verifies with a live check first.
  """
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Attention.Fleet
  alias Custode.Attention.Verify
  alias Custode.Disowned
  alias Custode.Repository
  alias Custode.Test.FakeGitHubFetcher

  defmodule FakeOps do
    @moduledoc false
    @behaviour Custode.Repository.OpsBehaviour

    def pr_checks(_owner, _repo, number) do
      Application.get_env(:custode, :fake_pr_checks, %{})
      |> Map.get(number, {:error, :not_faked})
    end

    def open_pr(_owner, _repo, _attrs), do: {:error, :unused}
    def open_issue(_owner, _repo, _attrs), do: {:error, :unused}
    def comment(_owner, _repo, _number, _body), do: {:error, :unused}
    def ready_pr(_owner, _repo, _number), do: {:error, :unused}
    def merge_pr(_owner, _repo, _number, _merge_method), do: {:error, :unused}
    def merge_pr_at_head(_owner, _repo, _number, _head_sha, _merge_method), do: {:error, :unused}
    def list_issues(_owner, _repo, _opts), do: {:error, :unused}
    def view_issue(_owner, _repo, _number), do: {:error, :unused}
    def list_prs(_owner, _repo, _opts), do: {:error, :unused}
    def view_pr(_owner, _repo, _number), do: {:error, :unused}
    def job_log_tail(_owner, _repo, _job_id), do: {:error, :unused}
    def pr_diff(_owner, _repo, _number), do: {:error, :unused}
    def review_snapshot(_owner, _repo, _number, _merge_method), do: {:error, :unused}
    def review_state(_owner, _repo, _number), do: :unreviewed
  end

  setup do
    Custode.PubSubBridge.subscribe()
    Verify.reset()
    put_env!(:repo_ops, FakeOps)

    repo = "acme/" <> uid("verify")
    routine = routine_fixture!(tmp_workspace!(), %{repo: repo, tags: [:repo]})

    start_supervised!(
      Supervisor.child_spec({Repository, %{name: repo, routine_id: routine.id}},
        id: :verify_test_repo
      )
    )

    on_exit(fn ->
      Custode.Repo.query!("DELETE FROM disowned_prs")
      Verify.reset()
    end)

    %{repo: repo, routine: routine}
  end

  defp checks!(by_number), do: put_env!(:fake_pr_checks, by_number)

  defp run(conclusion, status \\ "completed") do
    {:ok, %{sha: "abc1234", checks: [%{name: "test", status: status, conclusion: conclusion}]}}
  end

  # The overview cache is cold per test (the repo name is unique), so prime it
  # and wait for the fetch to land -- the dance a page render does implicitly.
  defp prime_overview!(repo, prs) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    overview = FakeGitHubFetcher.overview(repo, %{open_prs: %{total: length(prs), items: prs}})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

    :loading = Custode.GitHub.overview(repo)
    assert_receive {:repo_overview, ^repo}, 2_000
    :ok
  end

  defp pr(number, checks) do
    %{
      number: number,
      title: "pr #{number}",
      url: "https://x/#{number}",
      draft: true,
      checks: checks
    }
  end

  defp signal(routine_id), do: Map.fetch!(Fleet.signals_by_id(), routine_id)

  describe "verdict/2" do
    test "a cold read is :unverified, and the live check lands behind it", %{repo: repo} do
      checks!(%{400 => run("failure")})

      assert Verify.verdict(repo, 400) == :unverified
      assert_receive {:repo_overview, ^repo}, 2_000
      assert Verify.verdict(repo, 400) == :red
    end

    test "all-green checks land as :cleared", %{repo: repo} do
      checks!(%{400 => run("success")})

      assert Verify.verdict(repo, 400) == :unverified
      assert_receive {:repo_overview, ^repo}, 2_000
      assert Verify.verdict(repo, 400) == :cleared
    end

    test "an in-flight check is not a failure", %{repo: repo} do
      checks!(%{400 => run(nil, "in_progress")})

      assert Verify.verdict(repo, 400) == :unverified
      assert_receive {:repo_overview, ^repo}, 2_000
      assert Verify.verdict(repo, 400) == :cleared
    end

    test "a timed-out check is red; a skipped one is not", %{repo: repo} do
      checks!(%{400 => run("timed_out"), 401 => run("skipped")})

      assert Verify.verdict(repo, 400) == :unverified
      assert Verify.verdict(repo, 401) == :unverified

      eventually(fn -> assert Verify.verdict(repo, 400) == :red end)
      eventually(fn -> assert Verify.verdict(repo, 401) == :cleared end)
    end

    test "a failed read records nothing, and the next read retries", %{repo: repo} do
      checks!(%{})

      assert Verify.verdict(repo, 400) == :unverified
      refute_receive {:repo_overview, ^repo}, 300
      assert Verify.verdict(repo, 400) == :unverified

      checks!(%{400 => run("failure")})
      eventually(fn -> assert Verify.verdict(repo, 400) == :red end)
    end
  end

  describe "the gatherer's promotion" do
    test "a disowned red PR waits in :watching until the check is verified",
         %{repo: repo, routine: routine} do
      prime_overview!(repo, [pr(400, "FAILURE")])
      {:ok, _row} = Disowned.disown("agent", repo, 400)
      checks!(%{400 => run("failure")})

      # unverified: the cached tier only, which is this row minus the
      # escalation
      first = signal(routine.id)
      assert first.kind == :red_check
      assert first.group == :watching

      eventually(fn ->
        promoted = signal(routine.id)
        assert promoted.kind == :disowned_check
        assert promoted.group == :needs_you
      end)
    end

    test "a stale red check is dropped, not escalated", %{repo: repo, routine: routine} do
      prime_overview!(repo, [pr(400, "FAILURE")])
      {:ok, _row} = Disowned.disown("agent", repo, 400)
      checks!(%{400 => run("success")})

      # dropped entirely: the live checks say nothing is failing, so there is
      # no signal left to file in EITHER group, and the overview cache catches
      # up on its own cadence
      eventually(fn ->
        cleared = signal(routine.id)
        refute cleared.kind in [:red_check, :disowned_check]
        refute cleared.group == :needs_you
      end)
    end

    test "a red PR the agent still owns takes the cached signal, unverified",
         %{repo: repo, routine: routine} do
      prime_overview!(repo, [pr(400, "FAILURE")])
      checks!(%{400 => run("success")})

      assert signal(routine.id).kind == :red_check
      assert signal(routine.id).group == :watching

      # nothing was verified: an owned red check never promotes, so there is
      # nothing for staleness to be wrong about
      refute_receive {:repo_overview, ^repo}, 300
      assert Verify.verdict(repo, 400) == :unverified
    end
  end
end
