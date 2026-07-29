defmodule Custode.Workspace.Git do
  @moduledoc false

  def revision(repository_path, ref), do: git(repository_path, ["rev-parse", ref])

  def branch(workspace_path),
    do: git(workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"])

  def remote_revision(repository_path, remote, branch)
      when is_binary(remote) and is_binary(branch) do
    ref = "refs/heads/#{branch}"

    case System.cmd(
           "git",
           ["-C", repository_path, "ls-remote", "--heads", remote, ref],
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        {:ok, nil}

      {output, 0} ->
        case output |> String.trim() |> String.split(~r/\s+/, parts: 2) do
          [revision, ^ref] -> {:ok, revision}
          _unexpected -> {:error, :remote_branch_result_invalid}
        end

      {output, status} ->
        {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  def fetch_commit(repository_path, remote, revision) do
    case System.cmd(
           "git",
           ["-C", repository_path, "fetch", "--no-tags", remote, revision],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  def commit_parent(repository_path, revision),
    do: git(repository_path, ["rev-parse", "#{revision}^"])

  def commit_subject(repository_path, revision),
    do: git(repository_path, ["log", "-1", "--format=%s", revision])

  def changed_files_between(repository_path, from_revision, to_revision) do
    with {:ok, output} <-
           git(repository_path, [
             "diff",
             "--name-only",
             "-z",
             from_revision,
             to_revision,
             "--"
           ]) do
      {:ok, output |> nul_paths() |> Enum.sort()}
    end
  end

  def clean?(workspace_path) do
    with {:ok, output} <-
           git(workspace_path, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, output == ""}
    end
  end

  def matches_commit?(workspace_path, revision) do
    case System.cmd(
           "git",
           ["-C", workspace_path, "diff", "--quiet", revision, "--"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        compare_untracked_to_commit(workspace_path, revision)

      {_output, 1} ->
        {:ok, false}

      {output, status} ->
        {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  def reset_hard(workspace_path, revision) do
    with {:ok, _output} <- git(workspace_path, ["reset", "--hard", revision]) do
      :ok
    end
  end

  def commit_all(workspace_path, message) when is_binary(message) and message != "" do
    with {:ok, _output} <- git(workspace_path, ["add", "--all"]),
         {:ok, _output} <- git(workspace_path, ["commit", "-m", message]) do
      revision(workspace_path, "HEAD")
    end
  end

  def push(repository_path, remote, branch, revision)
      when is_binary(remote) and is_binary(branch) and is_binary(revision) do
    case System.cmd(
           "git",
           [
             "-C",
             repository_path,
             "push",
             remote,
             "#{revision}:refs/heads/#{branch}"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  def changed_files(workspace_path) do
    with {:ok, tracked} <- git(workspace_path, ["diff", "--name-only", "-z", "HEAD", "--"]),
         {:ok, untracked} <-
           git(workspace_path, ["ls-files", "--others", "--exclude-standard", "-z"]) do
      {:ok,
       (nul_paths(tracked) ++ nul_paths(untracked))
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  def diff(workspace_path) do
    with {:ok, tracked} <-
           git(workspace_path, ["diff", "--binary", "--no-ext-diff", "HEAD", "--"]),
         {:ok, untracked} <-
           git(workspace_path, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, patches} <- untracked_patches(workspace_path, nul_paths(untracked)) do
      {:ok, join_patches([tracked | patches])}
    end
  end

  def workspace_revision(workspace_path) do
    with {:ok, head_revision} <- revision(workspace_path, "HEAD"),
         {:ok, changed_files} <- changed_files(workspace_path),
         {:ok, diff} <- diff(workspace_path) do
      diff_digest = digest(diff)

      revision =
        [head_revision, diff_digest]
        |> :erlang.term_to_binary()
        |> digest()

      {:ok,
       %{
         "revision" => "sha256:#{revision}",
         "head_revision" => head_revision,
         "diff_digest" => diff_digest,
         "changed_files" => changed_files
       }}
    end
  end

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

  defp compare_untracked_to_commit(workspace_path, revision) do
    with {:ok, untracked} <-
           git(workspace_path, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, tree_paths} <-
           git(workspace_path, ["ls-tree", "-r", "--name-only", "-z", revision]) do
      compare_untracked_paths(
        workspace_path,
        revision,
        nul_paths(untracked),
        MapSet.new(nul_paths(tree_paths))
      )
    end
  end

  defp compare_untracked_paths(workspace_path, revision, paths, tree_paths) do
    if Enum.all?(paths, &MapSet.member?(tree_paths, &1)) do
      untracked_matches_tree?(workspace_path, revision, paths)
    else
      {:ok, false}
    end
  end

  defp untracked_matches_tree?(workspace_path, revision, paths) do
    Enum.reduce_while(paths, {:ok, true}, fn path, _matches ->
      compare_blob(workspace_path, revision, path)
    end)
  end

  defp compare_blob(workspace_path, revision, path) do
    with {:ok, workspace_blob} <- git(workspace_path, ["hash-object", "--", path]),
         {:ok, tree_blob} <- git(workspace_path, ["rev-parse", "#{revision}:#{path}"]) do
      if workspace_blob == tree_blob,
        do: {:cont, {:ok, true}},
        else: {:halt, {:ok, false}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp untracked_patches(workspace_path, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, patches} ->
      case System.cmd(
             "git",
             [
               "-C",
               workspace_path,
               "diff",
               "--no-index",
               "--binary",
               "--",
               "/dev/null",
               path
             ],
             stderr_to_stdout: true
           ) do
        {output, status} when status in [0, 1] ->
          {:cont, {:ok, [String.trim_trailing(output) | patches]}}

        {output, status} ->
          {:halt, {:error, {:git_failed, status, String.trim(output)}}}
      end
    end)
    |> case do
      {:ok, patches} -> {:ok, Enum.reverse(patches)}
      {:error, _reason} = error -> error
    end
  end

  defp nul_paths(""), do: []
  defp nul_paths(output), do: String.split(output, <<0>>, trim: true)

  defp join_patches(patches) do
    patches
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> ""
      joined -> joined <> "\n"
    end
  end

  defp digest(body) do
    :sha256
    |> :crypto.hash(body)
    |> Base.encode16(case: :lower)
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end
end
