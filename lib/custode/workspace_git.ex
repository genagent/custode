defmodule Custode.Workspace.Git do
  @moduledoc false

  def revision(repository_path, ref), do: git(repository_path, ["rev-parse", ref])

  def tracked_clean?(repository_path) do
    case System.cmd("git", ["-C", repository_path, "diff", "--quiet", "HEAD", "--"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, 1} -> {:error, {:repository_dirty, String.trim(output)}}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  def prepare(repository_path, workspace_path, branch, revision) do
    if File.dir?(workspace_path) do
      inspect_workspace(repository_path, workspace_path, branch, revision)
    else
      case System.cmd(
             "git",
             [
               "-C",
               repository_path,
               "worktree",
               "add",
               "-b",
               branch,
               workspace_path,
               revision
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> inspect_workspace(repository_path, workspace_path, branch, revision)
        {output, status} -> {:error, {:worktree_add_failed, status, String.trim(output)}}
      end
    end
  end

  def inspect_workspace(repository_path, workspace_path, branch, revision) do
    with {:ok, observed_revision} <- revision(workspace_path, "HEAD"),
         :ok <- matching_revision(observed_revision, revision),
         {:ok, observed_branch} <- git(workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"]),
         :ok <- matching_branch(observed_branch, branch),
         :ok <- ownership(repository_path, workspace_path) do
      {:ok, %{path: Path.expand(workspace_path), branch: branch, revision: revision}}
    end
  end

  def remove(repository_path, workspace_path) do
    with :ok <- ownership(repository_path, workspace_path) do
      case System.cmd(
             "git",
             ["-C", repository_path, "worktree", "remove", workspace_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:worktree_remove_failed, status, String.trim(output)}}
      end
    end
  end

  def ownership(repository_path, workspace_path) do
    expected_root = Path.expand(workspace_path)
    expected_common = Path.join(Path.expand(repository_path), ".git")

    with {:ok, observed_root} <- git(workspace_path, ["rev-parse", "--show-toplevel"]),
         {:ok, common} <- git(workspace_path, ["rev-parse", "--git-common-dir"]),
         true <- same_file?(observed_root, expected_root),
         true <- same_file?(expand_git_path(workspace_path, common), expected_common) do
      :ok
    else
      _other -> {:error, :workspace_ownership_unproven}
    end
  end

  defp expand_git_path(workspace_path, path) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: Path.expand(path, workspace_path)
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.inode == right_stat.inode and left_stat.major_device == right_stat.major_device
    else
      _error -> false
    end
  end

  defp matching_revision(revision, revision), do: :ok

  defp matching_revision(observed, _expected),
    do: {:error, {:workspace_revision_mismatch, observed}}

  defp matching_branch(branch, branch), do: :ok
  defp matching_branch(observed, _expected), do: {:error, {:workspace_branch_mismatch, observed}}

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end
end
