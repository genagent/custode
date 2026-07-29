defmodule Custode.MigrationRepairTest do
  use ExUnit.Case, async: false

  alias Custode.Migrations

  defmodule Repo do
    use Ecto.Repo,
      otp_app: :custode,
      adapter: Ecto.Adapters.SQLite3
  end

  @parked_version 20_260_722_000_004
  @panel_columns ~w(id routine_id html status inserted_at updated_at)

  setup do
    previous = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)
    on_exit(fn -> Code.compiler_options(ignore_module_conflict: previous) end)
  end

  test "fresh and parked-migration databases converge without losing v1 panel rows" do
    fresh_columns =
      with_database("fresh", fn ->
        migrate_all()
        panel_columns()
      end)

    {repaired_columns, repaired_row} =
      with_database("repaired", fn ->
        Ecto.Migrator.run(Repo, Migrations.path(), :up,
          to: @parked_version,
          log: false
        )

        Repo.query!(
          """
          INSERT INTO agent_panels
            (routine_id, html, status, inserted_at, updated_at, kind)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          ["caretaker", "<p>still here</p>", "approved", timestamp(), timestamp(), "html"]
        )

        migrate_all()

        row =
          Repo.query!("SELECT routine_id, html, status FROM agent_panels").rows

        {panel_columns(), row}
      end)

    assert fresh_columns == @panel_columns
    assert repaired_columns == fresh_columns
    assert repaired_row == [["caretaker", "<p>still here</p>", "approved"]]
  end

  defp with_database(label, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "custode-migration-#{label}-#{System.unique_integer([:positive])}.db"
      )

    {:ok, pid} = Repo.start_link(database: path, pool_size: 1, log: false)

    try do
      fun.()
    after
      GenServer.stop(pid)
      File.rm(path)
      File.rm(path <> "-shm")
      File.rm(path <> "-wal")
    end
  end

  defp migrate_all do
    Ecto.Migrator.run(Repo, Migrations.path(), :up, all: true, log: false)
  end

  defp panel_columns do
    Repo.query!("PRAGMA table_info(agent_panels)").rows
    |> Enum.map(&Enum.at(&1, 1))
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
