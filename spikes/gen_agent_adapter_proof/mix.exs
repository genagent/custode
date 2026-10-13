defmodule AdapterProof.MixProject do
  use Mix.Project

  def project do
    [
      app: :adapter_proof,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: ["lib", "test/support"],
      deps: [
        {:gen_agent, "== 0.7.0", override: true},
        {:gen_agent_claude, "== 0.2.7"},
        {:claude_wrapper, "== 0.15.3"},
        {:forcola, "== 0.6.0"},
        {:oban, "== 2.24.1"},
        {:ecto_sqlite3, "== 0.25.0"},
        {:jason, "~> 1.4"},
        {:credo, "~> 1.7", runtime: false},
        {:dialyxir, "~> 1.4", runtime: false}
      ],
      dialyzer: [plt_file: {:no_warn, "_build/proof.plt"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
