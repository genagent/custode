defmodule Custode.MixProject do
  use Mix.Project

  def project do
    [
      app: :custode,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Custode.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The agent layer lives on oban_claude's spike/agent-lifecycle branch,
      # so this must be a path dep to a sibling checkout ON THAT BRANCH.
      {:oban_claude, path: "../oban_claude"},
      {:oban, "~> 2.23"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      # The MCP server: agents running here can drive sibling agents/jobs.
      {:anubis_mcp, "~> 1.10"},
      {:bandit, "~> 1.5"}
    ]
  end
end
