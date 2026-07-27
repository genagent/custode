defmodule Custode.Sensors.ReleaseReadyTest do
  @moduledoc """
  Release watch (#336). Prompted by a real catch: the contributor worker
  surfaced a user asking for an mdbook-lint release, which worked because a
  human asked. This notices when a repo is due and nobody has said anything.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Sensors.ReleaseReady
  alias Custode.Test.FakeGitHubFetcher

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    repo = "acme/" <> uid("rel")

    args = %{
      "sensor_id" => uid("rel-sensor"),
      "notify" => routine.id,
      "repo" => repo
    }

    %{workspace: workspace, routine: routine, repo: repo, args: args}
  end

  defp fake_release!(repo, release) do
    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    overview = FakeGitHubFetcher.overview(repo, %{release: release})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))
  end

  defp release(fields) do
    Enum.into(fields, %{
      tag: "v1.0.0",
      published_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second),
      merged_since: 0,
      window_full?: false
    })
  end

  defp perform!(args), do: ReleaseReady.perform(%Oban.Job{args: args})
  defp notes(workspace), do: Path.wildcard(Path.join([workspace, "inbox", "sensor-*"]))

  describe "due" do
    test "enough unreleased work is due, whatever the clock says",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(
        repo,
        release(merged_since: 9, published_at: DateTime.utc_now())
      )

      :ok = perform!(args)

      assert [note] = notes(workspace)
      content = File.read!(note)
      assert content =~ "looks due for a release"
      assert content =~ "9 merged pull requests since"
      assert content =~ "last release v1.0.0"
    end

    test "a little unreleased work that has waited is also due",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 1))

      :ok = perform!(args)

      assert [note] = notes(workspace)
      assert File.read!(note) =~ "30 days since that release"
    end

    test "a repo that has never released is due once it has a pile",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(tag: nil, published_at: nil, merged_since: 12))

      :ok = perform!(args)

      assert [note] = notes(workspace)
      assert File.read!(note) =~ "no release has ever been published"
    end

    test "a saturated window reports a floor, not a total",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 20, window_full?: true))

      :ok = perform!(args)

      content = notes(workspace) |> hd() |> File.read!()
      assert content =~ "20+ merged pull requests"
      assert content =~ "there may be more"
    end
  end

  describe "not due" do
    test "nothing unreleased is not due, however long it has been",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(
        repo,
        release(merged_since: 0, published_at: DateTime.add(DateTime.utc_now(), -400 * 86_400))
      )

      :ok = perform!(args)
      assert notes(workspace) == []
    end

    test "one stale change is NOT a release", %{workspace: workspace, repo: repo, args: args} do
      # the `and` in the heuristic: a single docs fix three weeks old would
      # teach the operator to ignore this sensor by the second week
      fake_release!(
        repo,
        release(merged_since: 1, published_at: DateTime.add(DateTime.utc_now(), -5 * 86_400))
      )

      :ok = perform!(args)
      assert notes(workspace) == []
    end

    test "a fresh release with a few merges is not due yet",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 3, published_at: DateTime.utc_now()))

      :ok = perform!(args)
      assert notes(workspace) == []
    end

    test "missing release data is not evidence of anything",
         %{workspace: workspace, repo: repo, args: args} do
      overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
      overview = FakeGitHubFetcher.overview(repo) |> Map.delete(:release)
      put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:ok, overview}))

      :ok = perform!(args)
      assert notes(workspace) == []
    end
  end

  describe "thresholds and cadence" do
    test "both are tunable per sensor entry", %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 2, published_at: DateTime.utc_now()))

      :ok = perform!(Map.put(args, "min_merged", 2))
      assert [_note] = notes(workspace)
    end

    test "it says it once while the same release is newest",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 9))

      :ok = perform!(args)
      assert [_note] = notes(workspace)

      # still due next poll, same release: not news
      :ok = perform!(args)
      assert [_note] = notes(workspace)
    end

    test "a new release resets it, so the next pile is news again",
         %{workspace: workspace, repo: repo, args: args} do
      fake_release!(repo, release(merged_since: 9))
      :ok = perform!(args)
      assert [_note] = notes(workspace)

      # the operator released; later the repo grows overdue again
      fake_release!(repo, release(tag: "v1.1.0", merged_since: 9))
      :ok = perform!(args)

      assert [_first, _second] = notes(workspace)
    end
  end
end
