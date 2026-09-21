defmodule Custode.Gates.RiskTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Attention.Fleet
  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias Custode.Gates.Risk
  alias ObanClaude.Agent

  doctest Custode.Gates.Risk

  defmodule DiffOps do
    @moduledoc false
    def pr_diff(_owner, _repo, 12) do
      {:ok,
       %{
         files: [
           %{filename: "lib/a.ex", previous_filename: nil},
           %{filename: "lib/old_place.exs", previous_filename: "priv/repo/migrations/1_x.exs"}
         ]
       }}
    end

    def pr_diff(_owner, _repo, 13), do: {:ok, %{files: [%{filename: "README.md"}]}}
    def pr_diff(_owner, _repo, _number), do: {:error, "github: 502"}
  end

  describe "assess/1" do
    test "the highest level with a match wins, and only its paths are the evidence" do
      assert %{level: "high", matched: [".github/workflows/ci.yml"]} =
               Risk.assess(["mix.lock", ".github/workflows/ci.yml", "lib/a.ex"])

      assert %{level: "elevated", matched: ["Cargo.lock", "Cargo.toml"]} =
               Risk.assess(["Cargo.lock", "src/lib.rs", "Cargo.toml"])

      assert %{level: "low", matched: []} = Risk.assess(["src/lib.rs", "docs/guide.md"])
    end

    test "auth and secrets are matched as path segments, not as substrings" do
      assert %{level: "high"} = Risk.assess(["lib/app/auth/token.ex"])
      assert %{level: "high"} = Risk.assess(["config/secrets.exs"])
      assert %{level: "high"} = Risk.assess([".env.production"])
      # "author" and "authoring" are not auth
      assert %{level: "low"} = Risk.assess(["lib/authoring/notes.ex", "docs/author.md"])
    end

    test "a rename counts on both sides" do
      files = [%{filename: "lib/moved.exs", previous_filename: "priv/repo/migrations/1_x.exs"}]
      assert %{level: "high"} = files |> Risk.paths() |> Risk.assess()
    end
  end

  describe "a gate on a pull request" do
    setup do
      path = Path.join(System.tmp_dir!(), uid("risk") <> ".jsonl")
      put_env!(:feed_path, path)
      on_exit(fn -> File.rm(path) end)
      put_env!(:repo_ops, DiffOps)

      repo = "acme/" <> uid("risk")
      routine = routine_fixture!(tmp_workspace!(), %{repo: repo})
      :ok = Custode.Repository.ensure_served(repo, routine.id)
      %{routine: routine}
    end

    # run:stop first, then job_finished, the order the engine's worker uses
    defp gate!(routine, fields) do
      test_pid = self()

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            send(test_pid, {:enqueued, args, meta})
            {:ok, :queued}
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)
      :processing = Agent.submit_prompt(routine.id, "x")

      result =
        structured_result(
          Map.merge(%{"directive" => "request_permission", "action" => "do it"}, fields)
        )

      assert_receive {:enqueued, _args, %{"agent_id" => enqueued_id} = turn_meta}
                     when enqueued_id == routine.id

      :ok =
        Ingest.handle_event(
          [:oban_claude, :run, :stop],
          %{cost_usd: 0.0},
          %{result: result, job: %{meta: turn_meta}},
          nil
        )

      :ok = finish_agent_turn(turn_meta, result)
      {:ok, _status} = Agent.await(routine.id, :awaiting_permission, 1_000)

      eventually(fn ->
        assert [gate] = Gates.open_gates(routine.id)
        gate
      end)
    end

    test "records the PR it acts on, the risk, and the paths that set it", %{routine: routine} do
      gate = gate!(routine, %{"action_class" => "merge", "prs" => [12]})

      assert gate.pr_number == 12
      assert gate.risk == "high"
      assert Jason.decode!(gate.risk_paths) == ["priv/repo/migrations/1_x.exs"]

      signal = Enum.find(Fleet.signals(), &(&1.subject == routine.id))
      assert signal.headline == "wants your approval (merge, high risk)"
      assert signal.detail =~ "risk: priv/repo/migrations/1_x.exs"
    end

    test "a docs-only pull request is low, with nothing to point at", %{routine: routine} do
      gate = gate!(routine, %{"action_class" => "ready_pr", "prs" => [13]})

      assert gate.risk == "low"
      assert Jason.decode!(gate.risk_paths) == []
    end

    test "a diff that cannot be read leaves the risk unknown, which is not low",
         %{routine: routine} do
      gate = gate!(routine, %{"action_class" => "merge", "prs" => [99]})

      assert gate.pr_number == 99
      assert gate.risk == nil
    end

    test "no risk is claimed without exactly one PR, or for work that has no diff yet",
         %{routine: routine} do
      assert %{pr_number: nil, risk: nil} =
               gate!(routine, %{"action_class" => "merge", "prs" => [12, 13]})
    end

    # a reviewer has no repository of its own (#542)
    test "a routine with no repo gets the risk of the repository its turn named",
         %{routine: %{repo: served}} do
      reviewer = routine_fixture!(tmp_workspace!(), %{})
      assert reviewer.repo == nil

      gate = gate!(reviewer, %{"action_class" => "review", "prs" => [12], "repo" => served})

      assert gate.repo == served
      assert gate.risk == "high"
    end

    test "the declared repo wins over the routine's own", %{routine: routine} do
      other = "acme/" <> uid("other")
      :ok = Custode.Repository.ensure_served(other, routine.id)

      gate = gate!(routine, %{"action_class" => "review", "prs" => [13], "repo" => other})

      assert gate.repo == other
      assert gate.risk == "low"
    end

    test "a declared repo that is not served leaves the risk unknown", %{routine: routine} do
      unserved = "acme/" <> uid("unserved")
      gate = gate!(routine, %{"action_class" => "review", "prs" => [12], "repo" => unserved})

      assert gate.repo == unserved
      assert gate.risk == nil
    end

    test "a malformed repo is ignored, and the routine's own is read", %{routine: routine} do
      for junk <- ["not a repo", "../../etc/passwd", "a/b/c", 42] do
        assert Custode.Repository.well_formed(junk) == nil
      end

      gate = gate!(routine, %{"action_class" => "merge", "prs" => [12], "repo" => "a/b/c"})

      assert gate.repo == nil
      assert gate.risk == "high"
    end

    test "an implement gate names no PR even when the turn touched one", %{routine: routine} do
      assert %{pr_number: nil, risk: nil} =
               gate!(routine, %{"action_class" => "implement", "prs" => [12]})
    end
  end
end
