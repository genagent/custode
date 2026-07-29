defmodule Custode.Repair.Handlers do
  @moduledoc "Reviewed deterministic handlers for bounded repository repair."

  alias Custode.Verification.CommandSpec

  @environment_allowlist ~w(HOME PATH LANG LC_ALL MIX_HOME HEX_HOME OBAN_CLAUDE_PATH)

  @spec fetch(String.t(), keyword()) ::
          {:ok, :claude | :verification_retry | CommandSpec.t()} | {:error, term()}
  def fetch("claude", _options), do: {:ok, :claude}
  def fetch("verification_retry", _options), do: {:ok, :verification_retry}

  def fetch("elixir_format", options) do
    CommandSpec.new(%{
      name: "repair_format",
      category: "format",
      argv: ~w(mix format),
      working_directory: ".",
      environment_allowlist: @environment_allowlist,
      environment: environment(options),
      timeout_ms: 120_000,
      output_limit_bytes: 1_000_000,
      tail_bytes: 8_000,
      expected_exit_codes: [0],
      risk: "internal_write",
      shell: false,
      reviewed: true
    })
  end

  def fetch("git_replay", options) do
    with old_base when is_binary(old_base) <- options[:old_base_revision],
         new_base when is_binary(new_base) <- options[:new_base_revision],
         head when is_binary(head) <- options[:head_revision] do
      CommandSpec.new(%{
        name: "repair_replay",
        category: "repository",
        argv: ["git", "read-tree", "-m", "-u", old_base, new_base, head],
        working_directory: ".",
        environment_allowlist: @environment_allowlist,
        environment: environment(options),
        timeout_ms: 120_000,
        output_limit_bytes: 1_000_000,
        tail_bytes: 8_000,
        expected_exit_codes: [0],
        risk: "internal_write",
        shell: false,
        reviewed: true
      })
    else
      _missing -> {:error, :git_replay_revision_missing}
    end
  end

  def fetch(_handler, _options), do: {:error, :unknown_repair_handler}

  defp environment(options) do
    environment = System.get_env() |> Map.take(@environment_allowlist)

    case Keyword.get(options, :repository_path) do
      repository_path when is_binary(repository_path) ->
        dependency = Path.expand("../oban_claude", repository_path)

        if File.dir?(dependency),
          do: Map.put(environment, "OBAN_CLAUDE_PATH", dependency),
          else: Map.delete(environment, "OBAN_CLAUDE_PATH")

      _missing ->
        environment
    end
  end
end
