defmodule Custode.WorkTablesCompleteTest do
  # The guard that makes Custode.TestHelpers.work_tables/0 safe to rely on
  # (#419). Without it the list is just another hand-maintained copy, and the
  # whole point is that there should be exactly one and it should not be able
  # to fall behind the schema.
  use ExUnit.Case, async: false

  alias Custode.{Repo, TestHelpers}

  @kernel_roots ~w(missions work_items attempts artifacts context_bundles)

  test "every table referencing the work kernel is in the cleanup list" do
    listed = MapSet.new(TestHelpers.work_tables())
    missing = MapSet.difference(referencing_tables(), listed)

    assert MapSet.equal?(missing, MapSet.new()), """
    These tables reference the work kernel but are not in
    Custode.TestHelpers.work_tables/0:

        #{missing |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n    ")}

    Add each one, positioned BEFORE anything it references, or a module that
    clears the kernel will fail with a foreign-key error as soon as another
    module leaves one of these rows behind.
    """
  end

  test "the list contains no table that no longer exists" do
    stale = MapSet.difference(MapSet.new(TestHelpers.work_tables()), existing_tables())

    assert MapSet.equal?(stale, MapSet.new()),
           "work_tables/0 names tables that are not in the schema: #{inspect(MapSet.to_list(stale))}"
  end

  test "truncate_work! clears the kernel and can be run twice" do
    assert TestHelpers.truncate_work!() == :ok
    # idempotent: a second pass on an already-empty schema must not raise
    assert TestHelpers.truncate_work!() == :ok

    for table <- TestHelpers.work_tables() do
      assert count(table) == 0, "#{table} still has rows after truncate_work!"
    end
  end

  defp referencing_tables do
    @kernel_roots
    |> Enum.flat_map(fn root ->
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE ?",
        ["%REFERENCES \"#{root}\"%"]
      ).rows
      |> List.flatten()
    end)
    |> MapSet.new()
  end

  defp existing_tables do
    Repo.query!("SELECT name FROM sqlite_master WHERE type='table'").rows
    |> List.flatten()
    |> MapSet.new()
  end

  defp count(table) do
    Repo.query!("SELECT COUNT(*) FROM #{table}").rows |> List.flatten() |> hd()
  end
end
