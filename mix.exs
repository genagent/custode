defmodule Custode.MixProject do
  use Mix.Project

  def project do
    [
      app: :custode,
      version: "0.3.0",
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
      wrapper_dep(:oban_claude, "~> 0.10.2", "OBAN_CLAUDE_PATH"),
      wrapper_dep(:oban_codex, "~> 0.7.1", "OBAN_CODEX_PATH"),
      # Terminate the CLI process group on turn timeout or worker death.
      {:forcola, "~> 0.6.0"},
      {:oban, "~> 2.23"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      # The MCP server: agents running here can drive sibling agents/jobs.
      {:snodo_plug, "~> 0.4.1"},
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

  defp wrapper_dep(application, requirement, path_variable) do
    case System.get_env(path_variable) do
      path when is_binary(path) and path != "" -> {application, path: path}
      _unset -> {application, requirement}
    end
  end
end
