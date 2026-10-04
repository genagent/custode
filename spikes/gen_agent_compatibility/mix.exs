defmodule CustodeGenAgentProof.MixProject do
  use Mix.Project

  def project do
    [
      app: :custode_gen_agent_proof,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        {:gen_agent, "== 0.6.2", override: true},
        {:gen_agent_ensemble, "== 0.6.1"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
