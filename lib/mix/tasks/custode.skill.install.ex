defmodule Mix.Tasks.Custode.Skill.Install do
  @shortdoc "Install the Custode operator skill for Claude Code, Codex, or both"

  @moduledoc """
  Install the same provider-neutral operator skill for either supported host:

      mix custode.skill.install claude
      mix custode.skill.install codex
      mix custode.skill.install all

  Older and locally modified package files are preserved unless `--force` is
  supplied. Unrelated files in the skill directory are always preserved. This
  task compiles the artifact but never starts Custode.
  """
  use Mix.Task

  alias Custode.OperatorSkill

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [force: :boolean])

    target = parse_target(rest, invalid)
    Mix.Task.run("compile")

    case OperatorSkill.install(target, force: opts[:force] == true) do
      {:ok, results} ->
        Enum.each(results, &report/1)
        Mix.shell().info("Restart the host to discover #{OperatorSkill.name()}.")

      {:error, {:conflict, path}} ->
        Mix.raise("#{path} has local changes; review them, then rerun with --force")

      {:error, {:stale, path}} ->
        Mix.raise("#{path} is an older package; review it, then rerun with --force")

      {:error, {:install_busy, path}} ->
        Mix.raise(
          "another operator skill install owns #{path}; retry after it exits. " <>
            "If no installer is running, inspect and remove the stale lock"
        )

      {:error, reason} ->
        Mix.raise("operator skill install failed: #{inspect(reason)}")
    end
  end

  defp parse_target([target], []) when target in ~w(claude codex all),
    do: String.to_existing_atom(target)

  defp parse_target(_rest, _invalid) do
    Mix.raise("usage: mix custode.skill.install <claude|codex|all> [--force]")
  end

  defp report(%{
         target: target,
         path: path,
         status: status,
         version: version,
         digest: digest
       }) do
    Mix.shell().info(
      "#{status_label(status)} #{version} (#{String.slice(digest, 0, 12)}) " <>
        "for #{host_label(target)} at #{path}"
    )
  end

  defp status_label(:installed), do: "Installed"
  defp status_label(:updated), do: "Updated"
  defp status_label(:current), do: "Already current:"

  defp host_label(:claude), do: "Claude Code"
  defp host_label(:codex), do: "Codex"
end
