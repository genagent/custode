defmodule Custode.Operator.DirectoryBrowser do
  @moduledoc "A read-only host directory browser constrained to configured roots."

  def roots do
    configured = Application.get_env(:custode, :checkout_roots, [])

    (configured ++ recent_roots() ++ [Path.dirname(Custode.Home.root())])
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  def list(nil), do: list(hd(roots()))

  def list(path) when is_binary(path) do
    expanded = Path.expand(path)

    with :ok <- within_roots(expanded), {:ok, names} <- File.ls(expanded) do
      directories =
        names
        |> Enum.map(&Path.join(expanded, &1))
        |> Enum.filter(&safe_directory?/1)
        |> Enum.sort()

      {:ok, %{path: expanded, parent: parent(expanded), directories: directories, roots: roots()}}
    end
  end

  def suggest(repository) when is_binary(repository) do
    name = repository |> String.split("/") |> List.last()
    Path.join(hd(roots()), name)
  end

  defp recent_roots do
    for routine <- Custode.Routine.all(),
        is_binary(routine.repo),
        is_binary(routine.working_dir),
        do: Path.dirname(routine.working_dir)
  end

  defp within_roots(path) do
    if Enum.any?(roots(), &inside?(path, &1)), do: :ok, else: {:error, :outside_configured_roots}
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp safe_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      _other -> false
    end
  end

  defp parent(path) do
    candidate = Path.dirname(path)
    if candidate != path and Enum.any?(roots(), &inside?(candidate, &1)), do: candidate
  end
end
