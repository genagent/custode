defmodule Custode.AggregateMetricsTest do
  @moduledoc """
  The measurements #339's aggregate framing needs, and an honest account of
  the one it cannot make yet.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Feed
  alias Custode.Metrics

  setup do
    path = Path.join(System.tmp_dir!(), uid("agg") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    clean = fn -> Custode.Repo.query!("DELETE FROM feed_entries") end
    clean.()
    on_exit(clean)

    %{agent: uid("agg-agent")}
  end

  defp resolved!(agent, resolution, ago \\ 0) do
    at = DateTime.add(DateTime.utc_now(), -ago, :second)

    Custode.Repo.insert!(%Feed.Entry{
      event: "needs_approval",
      agent: agent,
      at: at,
      entry:
        Jason.encode!(%{"event" => "needs_approval", "agent" => agent, "resolved" => resolution})
    })
  end

  defp opened!(agent, repo, number, ago \\ 0) do
    at = DateTime.add(DateTime.utc_now(), -ago, :second)

    Custode.Repo.insert!(%Feed.Entry{
      event: "repo_verb",
      agent: agent,
      at: at,
      entry:
        Jason.encode!(%{
          "event" => "repo_verb",
          "agent" => agent,
          "verb" => "open_pr",
          "repo" => repo,
          "number" => number
        })
    })
  end

  describe "gate_outcomes/1" do
    test "counts approvals, rejections and answers per agent", %{agent: agent} do
      resolved!(agent, "approved")
      resolved!(agent, "approved")
      resolved!(agent, "rejected")
      resolved!(agent, "answered")

      assert %{"approved" => 2, "rejected" => 1, "answered" => 1} =
               Metrics.gate_outcomes(7)[agent]
    end

    test "separates agents, which is what makes the number useful", %{agent: agent} do
      other = uid("other")
      resolved!(agent, "rejected")
      resolved!(other, "approved")

      outcomes = Metrics.gate_outcomes(7)

      assert outcomes[agent] == %{"rejected" => 1}
      assert outcomes[other] == %{"approved" => 1}
    end

    test "respects the window", %{agent: agent} do
      resolved!(agent, "approved", 30 * 86_400)
      assert Metrics.gate_outcomes(7) == %{}
    end

    test "an unresolved gate is not an outcome", %{agent: agent} do
      Custode.Repo.insert!(%Feed.Entry{
        event: "needs_approval",
        agent: agent,
        at: DateTime.utc_now(),
        entry: Jason.encode!(%{"event" => "needs_approval", "agent" => agent})
      })

      assert Metrics.gate_outcomes(7) == %{}
    end
  end

  describe "prs_opened/1" do
    test "groups opened PRs by agent, with repo and number", %{agent: agent} do
      opened!(agent, "acme/one", 7)
      opened!(agent, "acme/one", 9)

      assert Metrics.prs_opened(7)[agent] == [{"acme/one", 7}, {"acme/one", 9}]
    end

    test "other repo verbs are not PRs opened", %{agent: agent} do
      Custode.Repo.insert!(%Feed.Entry{
        event: "repo_verb",
        agent: agent,
        at: DateTime.utc_now(),
        entry:
          Jason.encode!(%{
            "event" => "repo_verb",
            "agent" => agent,
            "verb" => "comment",
            "repo" => "acme/one",
            "number" => 7
          })
      })

      assert Metrics.prs_opened(7) == %{}
    end

    # The honest limit, asserted so it cannot be quietly forgotten: custode
    # records the verbs it performs, and merging is not one of them. This
    # measures what the fleet PUT UP, never what shipped.
    test "says nothing about what landed", %{agent: agent} do
      opened!(agent, "acme/one", 7)

      assert Metrics.prs_opened(7)[agent] == [{"acme/one", 7}]
      refute function_exported?(Metrics, :landed_by_day, 1)
    end
  end
end
