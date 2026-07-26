defmodule Custode.Migrations do
  @moduledoc """
  What `mix custode doctor` needs to know about migrations before a boot
  (#311), and the pure functions behind it.

  ## Why this is a preflight concern

  Ecto refuses the ENTIRE migration run when two files share a version, not
  just the offending pair:

      ** (Ecto.MigrationError) migrations can't be executed,
         migration version 20260726000001 is duplicated

  It surfaces as a supervision-tree crash at boot, which means the operator
  finds out after the fleet is already down. The condition is detectable from
  filenames alone -- no database, no server, no network -- so it belongs in
  the check that runs first.

  It is also easy to create without noticing: two branches that each add a
  migration on the same day are independently green and jointly broken, since
  neither contains the other's file. That is exactly how #305 and #306
  produced one (fixed in #309).

  ## Why the database read is optional

  `pending/0` reports what a restart is about to do to the schema, which is
  worth saying out loud. But a fresh install has no database at all, and
  design/003's binary target makes that the NORMAL case rather than the rare
  one, so an absent database is an answer here and not a failure.

  This never creates a database. A preflight that brings into existence the
  thing it is inspecting is a different tool.
  """

  @doc "The migrations directory."
  @spec path() :: String.t()
  def path, do: Application.app_dir(:custode, "priv/repo/migrations")

  @doc "Migration filenames, or `[]` when the directory is missing."
  @spec files(String.t()) :: [String.t()]
  def files(dir \\ path()) do
    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.filter(&String.ends_with?(&1, ".exs")) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  @doc """
  The version prefix of a migration filename.

      iex> Custode.Migrations.version("20260726000001_add_asks.exs")
      "20260726000001"
  """
  @spec version(String.t()) :: String.t()
  def version(filename), do: filename |> String.split("_", parts: 2) |> hd()

  @doc """
  Versions claimed by more than one file, with the files that claim them.

  Pure, so the check that matters most is testable without touching a disk.

      iex> Custode.Migrations.duplicates(["1_a.exs", "1_b.exs", "2_c.exs"])
      [{"1", ["1_a.exs", "1_b.exs"]}]

      iex> Custode.Migrations.duplicates(["1_a.exs", "2_b.exs"])
      []
  """
  @spec duplicates([String.t()]) :: [{String.t(), [String.t()]}]
  def duplicates(filenames) do
    filenames
    |> Enum.group_by(&version/1)
    |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
    |> Enum.sort()
  end

  @doc "The configured SQLite path, or nil when the repo has none."
  @spec database_path() :: String.t() | nil
  def database_path do
    :custode |> Application.get_env(Custode.Repo, []) |> Keyword.get(:database)
  end

  @doc """
  How many migrations a boot would run.

    * `{:ok, count}` -- the database exists and this many are pending
    * `{:fresh, count}` -- no database yet; all of them run on first boot
    * `{:error, reason}` -- the database exists but could not be read
  """
  @spec pending() :: {:ok, non_neg_integer()} | {:fresh, non_neg_integer()} | {:error, term()}
  def pending do
    db = database_path()

    cond do
      is_nil(db) -> {:error, "no database configured for Custode.Repo"}
      not File.exists?(db) -> {:fresh, length(files())}
      true -> count_pending()
    end
  end

  defp count_pending do
    Ecto.Migrator.with_repo(Custode.Repo, fn repo ->
      repo
      |> Ecto.Migrator.migrations([path()])
      |> Enum.count(fn {status, _version, _name} -> status == :down end)
    end)
    |> case do
      {:ok, count, _apps} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
