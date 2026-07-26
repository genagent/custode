defmodule Custode.MigrationsTest do
  use ExUnit.Case, async: true

  alias Custode.Migrations

  doctest Custode.Migrations

  describe "duplicates/1 -- the check that matters" do
    test "no duplicates in a healthy set" do
      assert Migrations.duplicates([
               "20260726000001_add_issue_drafts.exs",
               "20260726000002_add_asks.exs",
               "20260726000003_add_workflow_runs.exs"
             ]) == []
    end

    test "catches the real collision from #305 and #306" do
      assert Migrations.duplicates([
               "20260725000001_add_workflow_node_results.exs",
               "20260726000001_add_issue_drafts.exs",
               "20260726000001_add_asks.exs"
             ]) == [
               {"20260726000001",
                ["20260726000001_add_issue_drafts.exs", "20260726000001_add_asks.exs"]}
             ]
    end

    test "reports every colliding version, not just the first" do
      dupes =
        Migrations.duplicates([
          "1_a.exs",
          "1_b.exs",
          "2_c.exs",
          "3_d.exs",
          "3_e.exs"
        ])

      assert Enum.map(dupes, &elem(&1, 0)) == ["1", "3"]
    end

    test "three files on one version is still one finding" do
      assert [{"1", files}] = Migrations.duplicates(["1_a.exs", "1_b.exs", "1_c.exs"])
      assert length(files) == 3
    end

    test "an empty set has no duplicates" do
      assert Migrations.duplicates([]) == []
    end
  end

  describe "version/1" do
    test "takes the prefix before the first underscore" do
      assert Migrations.version("20260726000002_add_asks.exs") == "20260726000002"
    end

    test "survives a name with several underscores" do
      assert Migrations.version("20260722000002_add_journal_compaction.exs") == "20260722000002"
    end
  end

  describe "files/1" do
    test "a missing directory is empty rather than a crash" do
      assert Migrations.files("/nonexistent-#{System.unique_integer([:positive])}") == []
    end

    test "ignores anything that is not a migration", %{} do
      dir = Path.join(System.tmp_dir!(), "mig-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "1_real.exs"), "")
      File.write!(Path.join(dir, "README.md"), "")

      assert Migrations.files(dir) == ["1_real.exs"]
    end
  end

  describe "the repo's own migrations" do
    # The regression guard for #309: whatever else changes, main must never
    # ship two files claiming one version, because Ecto refuses the entire
    # run and the fleet does not boot.
    test "have unique versions" do
      assert Migrations.duplicates(Migrations.files()) == []
    end
  end
end
