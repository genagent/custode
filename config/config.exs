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
      prompt: "Do your caretaker sweep now.",
      # Fleet powers: this agent gets the custode MCP tools (run_job,
      # start_agent, ...) so it can delegate to one-shot jobs and sub-agents.
      mcp: true
      # Other per-routine overrides:
      #   model: "haiku", max_budget_usd: 0.25, system_prompt: "..."
    },
    # custode working on custode: a repo caretaker running READ-ONLY at the
    # repo root (notebook in dev-workspace/), granted read-only git via Bash
    # patterns, proposing at most one small change per sweep -- and approved
    # changes run in an isolated git worktree a human merges. @daily on the
    # schedule; drive it by hand with Custode.beat("custode-dev").
    %{
      id: "custode-dev",
      cron: "@daily",
      workspace: "dev-workspace",
      working_dir: ".",
      repo: "genagent/custode",
      prompt: "Do your repository caretaker sweep now.",
      role: :repo_caretaker,
      mcp: true,
      # repo-context turns are pricier than workspace sweeps: a bigger
      # per-turn cap so an approved implementation can finish in one turn
      max_budget_usd: 5.0,
      # approved implementations compile and test; more room than a sweep
      max_turns: 40,
      daily_budget_usd: 25.0,
      extra_allowed_tools: [
        "Bash(git log:*)",
        "Bash(git status:*)",
        "Bash(git diff:*)",
        "Bash(git show:*)"
      ],
      approved_args: %{"permission_mode" => "bypass_permissions", "worktree" => "custode-dev"}
    },
    # Backlog workers: slowly work through a repo's open issues -- at most one
    # proposed item per sweep, always human-gated, approved work in an
    # isolated worktree.
    %{
      id: "redis-tower",
      cron: "@daily",
      workspace: "workspaces/redis-tower",
      repo: "joshrotenberg/redis-tower",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/redis-tower",
      prompt: "Do your backlog sweep now.",
      role: :backlog_worker,
      mcp: true,
      # opus: the operator wants backlog work done well; budgets sized to match
      model: "opus",
      max_budget_usd: 10.0,
      daily_budget_usd: 50.0,
      # implementation turns run cargo/mix suites; 15 minutes, not 200s
      timeout_ms: 900_000,
      # an approved implementation iterates edit/build/test well past the
      # default 20 agentic turns (redis-tower #465 railed on it)
      max_turns: 75,
      extra_allowed_tools: [
        "Bash(git log:*)",
        "Bash(git status:*)",
        "Bash(git diff:*)",
        "Bash(git show:*)",
        "Bash(gh issue list:*)",
        "Bash(gh issue view:*)",
        "Bash(gh pr list:*)",
        "Bash(gh pr view:*)"
      ],
      approved_args: %{
        "permission_mode" => "bypass_permissions",
        "worktree" => "custode-redis-tower"
      }
    },
    %{
      id: "git-spawn",
      cron: "@daily",
      workspace: "workspaces/git-spawn",
      repo: "joshrotenberg/git-spawn",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/git-spawn",
      prompt: "Do your backlog sweep now.",
      role: :backlog_worker,
      mcp: true,
      # opus: the operator wants backlog work done well; budgets sized to match
      model: "opus",
      max_budget_usd: 10.0,
      daily_budget_usd: 50.0,
      # implementation turns run cargo/mix suites; 15 minutes, not 200s
      timeout_ms: 900_000,
      # an approved implementation iterates edit/build/test well past the
      # default 20 agentic turns (redis-tower #465 railed on it)
      max_turns: 75,
      extra_allowed_tools: [
        "Bash(git log:*)",
        "Bash(git status:*)",
        "Bash(git diff:*)",
        "Bash(git show:*)",
        "Bash(gh issue list:*)",
        "Bash(gh issue view:*)",
        "Bash(gh pr list:*)",
        "Bash(gh pr view:*)"
      ],
      approved_args: %{
        "permission_mode" => "bypass_permissions",
        "worktree" => "custode-git-spawn"
      }
    },
    # The star tracker: daily delta report across joshrotenberg + genagent.
    %{
      id: "stars",
      cron: "@daily",
      workspace: "workspaces/stars",
      prompt: "Do your star sweep now.",
      role: :star_tracker,
      mcp: true,
      max_budget_usd: 1.0,
      daily_budget_usd: 5.0,
      extra_allowed_tools: ["Bash(gh repo list:*)"]
    },
    # The contributor watch, sensor-driven: the contributor-search sensor
    # (below) detects new items mechanically and drops an inbox note, whose
    # event kickoff wakes this agent to verify, journal, and alert. No
    # schedule of its own.
    %{
      id: "contributors",
      cron: :manual,
      workspace: "workspaces/contributors",
      prompt: "Do your contributor sweep now.",
      role: :contributor_watch,
      mcp: true,
      # a real sweep (search, filter, journal, remember a dozen items) costs
      # more than the trivial nothing-new case; cap sized for the real one
      max_budget_usd: 3.0,
      daily_budget_usd: 15.0,
      extra_allowed_tools: [
        "Bash(gh search:*)",
        "Bash(gh issue list:*)",
        "Bash(gh issue view:*)",
        "Bash(gh pr list:*)",
        "Bash(gh pr view:*)"
      ]
    }
  ],
  # Sensors: mechanical Oban workers (never claude) on their own schedule
  # and queue; they detect change and drop inbox notes, whose event kickoff
  # wakes the routine that judges. Cheap sensor, expensive brain.
  sensors: [
    %{
      id: "contributor-search",
      cron: "*/30 * * * *",
      module: Custode.Sensors.ContributorSearch,
      notify: "contributors",
      args: %{owners: ["joshrotenberg", "genagent"], exclude_authors: ["joshrotenberg"]}
    }
  ],
  # Defaults shared by every routine unless overridden per-entry.
  model: "sonnet",
  # The budget rails guard against runaway loops, NOT dollar cost: on a
  # subscription (claude Max) the CLI-reported cost_usd is notional, so
  # every cap here is sized as an "obviously wrong" threshold rather than
  # a spend target. Token-based accounting is the truer measure long-term.
  max_budget_usd: 2.0,
  # Daily (UTC) cap per routine: crossing it auto-pauses the routine
  # (resume is a human override; a restart leaks at most one turn). nil
  # disables. Per-routine override: daily_budget_usd in the routine map.
  daily_budget_usd: 25.0,
  # The activity feed (one JSON line per noteworthy event; see Custode.Feed).
  feed_path: "feed.jsonl",
  # macOS desktop notifications for events that need a human
  # (needs_approval / needs_input / turn_failed).
  desktop_notifications: true

config :custode, Custode.Repo,
  database: "custode.db",
  pool_size: 1,
  busy_timeout: 5_000,
  log: false

# The MCP endpoint (localhost only) agents use to drive sibling agents/jobs.
config :custode, mcp_port: 6161

# The dashboard (localhost only, no auth -- same caveat as the MCP endpoint).
config :custode, CustodeWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4646],
  server: true,
  secret_key_base: "custode-demo-secret-key-base-not-for-production-0123456789abcdef",
  live_view: [signing_salt: "custode-lv"],
  render_errors: [formats: [html: CustodeWeb.ErrorHTML], layout: false],
  pubsub_server: Custode.PubSub

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
