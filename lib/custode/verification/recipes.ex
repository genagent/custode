defmodule Custode.Verification.Recipes do
  @moduledoc """
  Reviewed verification recipes for the first repository vertical.

  Recipes are immutable declarative code. There is deliberately no runtime
  string or shell mutation surface in this slice.
  """

  alias Custode.Verification.Recipe

  @environment_allowlist ~w(HOME PATH LANG LC_ALL MIX_HOME HEX_HOME OBAN_CLAUDE_PATH)
  @output_limit_bytes 1_000_000
  @tail_bytes 8_000

  @doc "Select the reviewed recipe supported by one owned workspace."
  def for_workspace(workspace_path, options \\ []) when is_binary(workspace_path) do
    if File.regular?(Path.join(workspace_path, "mix.exs")) do
      elixir(options)
    else
      {:error, :unsupported_verification_recipe}
    end
  end

  @doc "The current Elixir repository recipe."
  def elixir(options \\ []) do
    environment = elixir_environment(options)

    Recipe.new(%{
      name: "elixir_repository",
      version: "1",
      commands: [
        command("format", "format", ~w(mix format --check-formatted), 120_000, environment),
        command(
          "compile",
          "static_analysis",
          ~w(mix compile --warnings-as-errors),
          300_000,
          environment
        ),
        command("credo", "repository", ~w(mix credo --strict), 300_000, environment),
        command("test", "test", ~w(mix test), 900_000, environment),
        command("dialyzer", "repository", ~w(mix dialyzer), 900_000, environment)
      ]
    })
  end

  @doc "Resolve one reviewed recipe reference without accepting command text."
  def fetch(name, version, options \\ [])
  def fetch("elixir_repository", "1", options), do: elixir(options)
  def fetch(_name, _version, _options), do: {:error, :unknown_verification_recipe}

  defp command(name, category, argv, timeout_ms, environment) do
    %{
      name: name,
      category: category,
      argv: argv,
      working_directory: ".",
      environment_allowlist: @environment_allowlist,
      environment: environment,
      timeout_ms: timeout_ms,
      output_limit_bytes: @output_limit_bytes,
      tail_bytes: @tail_bytes,
      expected_exit_codes: [0],
      risk: "internal_write",
      shell: false,
      reviewed: true
    }
  end

  defp elixir_environment(options) do
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
