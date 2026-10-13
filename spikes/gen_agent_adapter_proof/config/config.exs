import Config

config :adapter_proof, ecto_repos: [AdapterProof.Repo]
config :logger, level: :warning
config :claude_wrapper, runner: AdapterProof.GuardedRunner
