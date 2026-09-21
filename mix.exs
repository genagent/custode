defmodule Custode.MixProject do
  use Mix.Project

  def project do
    [
      app: :custode,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # PLTs live in priv/plts (gitignored) so CI can cache the directory on
      # the toolchain + mix.lock, the same shape oban_claude uses (#92).
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
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
      # The agent layer shipped in oban_claude 0.4.0; the path dep (ecosystem
      # convention for local apps) picks up in-flight changes from the sibling
      # checkout. Swap for {:oban_claude, "~> 0.4"} to run against hex.
      # OBAN_CLAUDE_PATH lets a worktree checkout (whose relative ".." differs)
      # point at the real sibling repo so mix compile/test work inside
      # .claude/worktrees/* -- proposed by the custode-dev routine.
      {:oban_claude, path: System.get_env("OBAN_CLAUDE_PATH", "../oban_claude")},
      # Codex implements the same Executor contract through its sibling Oban
      # integration. Keep the path configurable for isolated worktree builds.
      {:oban_codex, path: System.get_env("OBAN_CODEX_PATH", "../oban_codex")},
      # Terminate the CLI process group on turn timeout or worker death.
      {:forcola, "~> 0.3.3"},
      {:oban, "~> 2.23"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      # The MCP server: agents running here can drive sibling agents/jobs.
      {:anubis_mcp, "~> 2.0"},
      # Typed GitHub client: repo panels on agent pages (reads); verb tools later.
      {:gh_ex, "~> 0.3"},
      # HTTP client (also a gh_ex dep): the boot MCP probe and CLI transport.
      {:req, "~> 0.5"},
      # Real timezones for the cron schedule (#17).
      {:tzdata, "~> 1.1"},
      # routines.toml (#41 / design 001): the roster as an operator-edited
      # data file; TOML because comments are load-bearing in this file.
      {:toml, "~> 0.7"},
      # Markdown rendering for agent output (journal tables and friends).
      {:mdex, "~> 0.13"},
      {:bandit, "~> 1.5"},
      # The dashboard: LiveView over the facade + PubSub, daisyUI via CDN
      # (no node/asset pipeline; see CustodeWeb.Layouts).
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # The mix custode CLI command tree (#45).
      {:cheer, "~> 0.2"}
    ]
  end
end
