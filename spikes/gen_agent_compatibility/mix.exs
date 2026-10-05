defmodule CustodeGenAgentProof.MixProject do
  use Mix.Project

  def project do
    [
      app: :custode_gen_agent_proof,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        {:gen_agent, "== 0.6.2", override: true},
        {:gen_agent_ensemble, "== 0.6.1"},
        {:gen_agent_claude, "== 0.2.6"},
        {:gen_agent_codex, "== 0.5.0"},
        {:oban_claude, "== 0.10.1"},
        {:oban_codex, "== 0.7.0"},
        {:claude_wrapper, "== 0.15.2"},
        {:codex_wrapper, "== 0.6.0"},
        {:forcola, "== 0.6.0"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
