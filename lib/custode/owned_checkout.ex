defmodule Custode.OwnedCheckout do
  @moduledoc """
  Paths and read-only inspection for routine-owned repository clones.

  An owned checkout has one deterministic location below Custode's data
  directory: `checkouts/<routine-id>`. This module does not create, update or
  remove that location. It gives those later operations one conservative
  answer about what is already there.

  Repository inspection uses `git` with an argument vector. It accepts the
  common GitHub HTTPS and SSH origin forms, compares repository names without
  case sensitivity, and never returns the raw origin URL, which may contain a
  credential.
  """

  alias Custode.{Home, Repository}

  @routine_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @typedoc "Why a destination cannot be used as the expected repository."
  @type mismatch_reason :: :origin_missing | :origin_unrecognized | :repository_mismatch

  @typedoc "The observed state of an owned checkout destination."
  @type inspection ::
          %{
            state: :missing | :empty | :occupied | :matching | :mismatched,
            path: String.t(),
            expected_repo: String.t(),
            observed_repo: String.t() | nil,
            reason: atom() | nil
          }

  @doc """
  Return the deterministic owned-checkout path for a routine.

  The routine id must be one safe path segment. Refusing unsafe ids instead of
  rewriting them prevents two distinct ids from collapsing onto one checkout.
  Pass `:root` to inspect a prospective data root without changing process
  environment.
  """
  @spec path(String.t(), keyword()) :: {:ok, String.t()} | {:error, :invalid_routine_id}
  def path(routine_id, opts \\ []) do
    if valid_routine_id?(routine_id) do
      root = opts |> Keyword.get(:root, Home.data_dir()) |> Path.expand()
      {:ok, Path.join([root, "checkouts", routine_id])}
    else
      {:error, :invalid_routine_id}
    end
  end

  @doc """
  Classify `destination` for the expected GitHub `owner/name` repository.

  Missing and empty destinations are available to a later provision step.
  Nonempty paths that are not repository roots are occupied. Repository roots
  are matching or mismatched according to their `origin` remote.
  """
  @spec inspect_destination(String.t(), String.t()) ::
          {:ok, inspection()} | {:error, :invalid_repository | {:inspection_failed, term()}}
  def inspect_destination(destination, expected_repo)
      when is_binary(destination) and is_binary(expected_repo) do
    case Repository.well_formed(expected_repo) do
      expected when is_binary(expected) ->
        destination
        |> Path.expand()
        |> inspect_path(expected)

      _invalid ->
        {:error, :invalid_repository}
    end
  end

  def inspect_destination(_destination, _expected_repo), do: {:error, :invalid_repository}

  @doc "Normalize a supported GitHub origin URL to its `owner/name`, without fetching."
  @spec repository_from_origin(String.t()) :: {:ok, String.t()} | {:error, :unrecognized_origin}
  def repository_from_origin(origin) when is_binary(origin) do
    origin
    |> String.trim()
    |> github_path()
    |> case do
      {:ok, path} -> normalize_repository_path(path)
      :error -> {:error, :unrecognized_origin}
    end
  end

  def repository_from_origin(_origin), do: {:error, :unrecognized_origin}

  defp valid_routine_id?(routine_id) when is_binary(routine_id) do
    routine_id not in [".", ".."] and Regex.match?(@routine_id, routine_id)
  end

  defp valid_routine_id?(_routine_id), do: false

  defp inspect_path(path, expected_repo) do
    case File.lstat(path) do
      {:error, :enoent} ->
        result(:missing, path, expected_repo)

      {:ok, %File.Stat{type: :directory}} ->
        inspect_directory(path, expected_repo)

      {:ok, _other} ->
        result(:occupied, path, expected_repo, reason: :not_a_directory)

      {:error, reason} ->
        {:error, {:inspection_failed, reason}}
    end
  end

  defp inspect_directory(path, expected_repo) do
    case File.ls(path) do
      {:ok, []} -> result(:empty, path, expected_repo)
      {:ok, _entries} -> inspect_repository(path, expected_repo)
      {:error, reason} -> {:error, {:inspection_failed, reason}}
    end
  end

  defp inspect_repository(path, expected_repo) do
    with {:ok, top_level} <- git(path, ["rev-parse", "--show-toplevel"]),
         true <- same_path?(path, top_level) do
      inspect_origin(path, expected_repo)
    else
      false -> result(:occupied, path, expected_repo, reason: :not_repository_root)
      {:error, _git_failure} -> result(:occupied, path, expected_repo, reason: :not_a_repository)
    end
  end

  defp inspect_origin(path, expected_repo) do
    with {:ok, origin} <- git(path, ["config", "--get", "remote.origin.url"]),
         {:ok, observed_repo} <- repository_from_origin(origin) do
      if same_repository?(observed_repo, expected_repo) do
        result(:matching, path, expected_repo, observed_repo: observed_repo)
      else
        result(:mismatched, path, expected_repo,
          observed_repo: observed_repo,
          reason: :repository_mismatch
        )
      end
    else
      {:error, {:git_failed, 1}} ->
        result(:mismatched, path, expected_repo, reason: :origin_missing)

      {:error, :unrecognized_origin} ->
        result(:mismatched, path, expected_repo, reason: :origin_unrecognized)

      {:error, reason} ->
        {:error, {:inspection_failed, reason}}
    end
  end

  defp result(state, path, expected_repo, opts \\ []) do
    {:ok,
     %{
       state: state,
       path: path,
       expected_repo: expected_repo,
       observed_repo: Keyword.get(opts, :observed_repo),
       reason: Keyword.get(opts, :reason)
     }}
  end

  defp same_repository?(left, right), do: String.downcase(left) == String.downcase(right)

  defp same_path?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.inode == right_stat.inode and left_stat.major_device == right_stat.major_device
    else
      _error -> false
    end
  end

  defp github_path("git@github.com:" <> path), do: {:ok, path}

  defp github_path(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: "github.com", path: path}
      when scheme in ["https", "ssh", "git"] and is_binary(path) ->
        {:ok, path}

      _other ->
        :error
    end
  end

  defp normalize_repository_path(path) do
    repository =
      path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
      |> String.trim_trailing(".git")

    if Repository.well_formed(repository) do
      {:ok, repository}
    else
      {:error, :unrecognized_origin}
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, status} -> {:error, {:git_failed, status}}
    end
  rescue
    error -> {:error, {:command_failed, Exception.message(error)}}
  end
end
