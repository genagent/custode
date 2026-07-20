import Config

config :custode,
  ecto_repos: [Custode.Repo],
  # Each entry is one always-on agent: a cron schedule + a workspace + a beat
  # prompt. The crontab entry that Custode builds from it is the WHOLE agent
  # spec (ObanClaude.Agent.Tick with if_offline: "start"), so agents cold-start
  # from the schedule after any restart. Add more maps to run a fleet -- e.g.
  # point a second one's :workspace at a repo checkout with its own :prompt.
  routines: [
    %{
      id: "custode",
      # A sonnet sweep costs ~$0.40, so every minute is ~$25/hour -- the
      # default is a calm every-10-minutes. For an attended demo, flip to
      # "* * * * *" (or just drive beats by hand with Custode.beat()).
      cron: "*/10 * * * *",
      # The directory this agent tends. Relative paths resolve from the cwd.
      workspace: "workspace",
      prompt: "Do your caretaker sweep now."
      # Optional per-routine overrides:
      #   model: "haiku", max_budget_usd: 0.25, system_prompt: "..."
    }
  ],
  # Defaults shared by every routine unless overridden per-entry.
  model: "sonnet",
  max_budget_usd: 0.75

config :custode, Custode.Repo,
  database: "custode.db",
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
