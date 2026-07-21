import Config

config :custode,
  ecto_repos: [Custode.Repo],
  # Each entry is one always-on agent: a cron schedule + a workspace + a beat
  # prompt. The crontab entry that Custode builds from it is the WHOLE agent
  # spec (ObanClaude.Agent.Tick with if_offline: "start"), so agents cold-start
  # from the schedule after any restart. Add more maps to run a fleet -- e.g.
  # point a second one's :workspace at a repo checkout with its own :prompt.
  # Profiles (#38's envelope layer, enabling #75's one-liner setup): a
  # routine names a profile and inherits the whole operational envelope,
  # then overrides freely (the routine entry wins; tags union; "{id}" in
  # approved_args templates to the routine id). sensors: [:ci] derives a
  # 15-minute CiStatus poll per repo-tied wearer.
  profiles: %{
    backlog_worker: %{
      cron: "@daily",
      prompt: "Do your backlog sweep now.",
      role: :backlog_worker,
      mcp: true,
      # opus: the operator wants backlog work done well; budgets sized to match
      model: "opus",
      max_budget_usd: 10.0,
      daily_budget_usd: 50.0,
      # implementation turns run cargo/mix suites; 15 minutes, not 200s
      timeout_ms: 900_000,
      # approved implementations iterate edit/build/test well past 20 turns
      max_turns: 75,
      tags: [:repo, :backlog],
      sensors: [:ci],
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
        "worktree" => "custode-{id}"
      }
    }
  },
  routines: [
    %{
      id: "custode",
      # A sonnet sweep costs ~$0.40, so every minute is ~$25/hour -- the
      # default is a calm every-10-minutes. For an attended demo, flip to
      # "* * * * *" (or just drive beats by hand with Custode.beat()).
      cron: "*/10 * * * *",
      # The directory this agent tends. Relative paths resolve from the cwd.
      workspace: "workspace",
      tags: [:meta],
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
      tags: [:repo, :elixir],
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
      id: "adrs",
      profile: :backlog_worker,
      repo: "joshrotenberg/adrs",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/adrs",
      tags: [:rust, :external]
    },
    %{
      id: "redis-tower",
      profile: :backlog_worker,
      repo: "joshrotenberg/redis-tower",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/redis-tower",
      tags: [:rust, :external]
    },
    %{
      id: "git-spawn",
      profile: :backlog_worker,
      repo: "joshrotenberg/git-spawn",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/git-spawn",
      tags: [:rust, :external]
    },
    %{
      id: "mcp-proxy",
      profile: :backlog_worker,
      repo: "joshrotenberg/mcp-proxy",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/mcp-proxy",
      tags: [:rust, :external]
    },
    %{
      id: "tower-mcp",
      profile: :backlog_worker,
      repo: "joshrotenberg/tower-mcp",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/tower-mcp",
      tags: [:rust, :external]
    },
    %{
      id: "tower-resilience",
      profile: :backlog_worker,
      repo: "joshrotenberg/tower-resilience",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/tower-resilience",
      tags: [:rust, :external]
    },
    # The star tracker: daily delta report across joshrotenberg + genagent.
    %{
      id: "stars",
      cron: "@daily",
      workspace: "workspaces/stars",
      tags: [:watch],
      prompt: "Do your star sweep now.",
      role: :star_tracker,
      mcp: true,
      max_budget_usd: 1.0,
      daily_budget_usd: 5.0,
      extra_allowed_tools: ["Bash(gh repo list:*)"]
    },
    # The earthquake watch: the first non-development routine. The
    # usgs-quakes sensor (below) polls the USGS feed mechanically; this
    # agent judges, journals, and escalates only what warrants a human.
    %{
      id: "quakes",
      cron: :manual,
      workspace: "workspaces/quakes",
      tags: [:watch, :world],
      prompt: "Do your earthquake sweep now.",
      role: :quake_watch,
      mcp: true,
      max_budget_usd: 1.0,
      daily_budget_usd: 5.0
    },
    # The contributor watch, sensor-driven: the contributor-search sensor
    # (below) detects new items mechanically and drops an inbox note, whose
    # event kickoff wakes this agent to verify, journal, and alert. No
    # schedule of its own.
    %{
      id: "contributors",
      cron: :manual,
      workspace: "workspaces/contributors",
      tags: [:watch],
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
    },
    # CI watch (one per repo-tied routine): a PR turning red wakes its
    # routine within the poll interval instead of at the next @daily sweep.
    %{
      id: "ci-custode-dev",
      cron: "*/15 * * * *",
      module: Custode.Sensors.CiStatus,
      notify: "custode-dev",
      args: %{repo: "genagent/custode"}
    },
    # The dead-man (#3): a sensor that watches the sensors; silence past
    # 2x cadence notes the meta-agent, whose orders escalate to a human.
    %{
      id: "deadman",
      cron: "*/30 * * * *",
      module: Custode.Sensors.Deadman,
      notify: "custode"
    },
    # The USGS earthquake poll: every 20 minutes, M4.5+ over the past day.
    %{
      id: "usgs-quakes",
      cron: "*/20 * * * *",
      module: Custode.Sensors.UsgsQuakes,
      notify: "quakes",
      args: %{min_magnitude: 4.5}
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
  desktop_notifications: true,
  # Notification/click links; point at the ts.net address once #65 is on.
  dashboard_base_url: "http://localhost:4646",
  # Mobile feed via ntfy (#13): set topic: to enable, e.g.
  #   ntfy: [topic: "custode-<long-random-suffix>", publish: :all]
  # publish: :all mirrors the whole feed (attention rings, the rest lands
  # silently); :attention sends alerts only. ntfy.sh topics are public to
  # anyone who guesses the name -- use a long random suffix or self-host
  # (url: defaults to https://ntfy.sh).
  ntfy: [topic: nil]

config :custode, Custode.Repo,
  database: "custode.db",
  # WAL lets readers run concurrently; a single connection made every
  # LiveView read queue behind telemetry writes (audit 2026-07-21)
  pool_size: 5,
  busy_timeout: 5_000,
  log: false

# The MCP endpoint (localhost only) agents use to drive sibling agents/jobs.
config :custode, mcp_port: 6161

# The policy layer (#50): fleet rules declared once, rendered into every
# binding agent's prompt AND shown on gate cards at review time. When verb
# tools (#10) exist, the same declarations back mechanical checks.
config :custode,
  policies: [
    %{
      id: :external_repo_writes,
      applies: [tag: :external],
      text:
        "This repository is the operator's public surface: never open or modify " <>
          "issues or PRs (beyond pushing to your OWN agent-authored PR branches) " <>
          "without an approved gate naming the exact action -- and PROPOSING " <>
          "that gate is encouraged whenever the work warrants it. Never open " <>
          "anything on a repository owned by a third party, ever."
    },
    %{
      id: :contributor_contact,
      applies: :all,
      text:
        "Never respond to, comment on, or start work against a third-party " <>
          "contributor's issue or PR without human approval THROUGH A GATE -- " <>
          "and a gate is yours to raise: when you see warranted engagement (a " <>
          "diagnosis worth sharing, a fix worth offering), PROPOSE it via " <>
          "request_permission with the exact action. Silence is only right " <>
          "when there is nothing worth proposing."
    },
    %{
      id: :conventional_commits,
      applies: [tag: :repo],
      text:
        "Conventional-commit style everywhere: commit messages, PR titles, and " <>
          "branch names (feat:/fix:/docs:/test:/chore:; branch prefixes to match)."
    },
    %{
      id: :draft_pr_first,
      applies: [tag: :repo],
      text:
        "Open a DRAFT PR as soon as branch work starts; mark it ready only when " <>
          "checks are green AND the approved action said to. Default: leave draft."
    },
    %{
      id: :merge,
      applies: [tag: :repo],
      value: :manual,
      text: "You never merge PRs. A human merges. No exceptions."
    }
  ]

# Fleet-wide external MCP servers (#46): written into one shared config file
# every mcp: true routine references, tool grants appended to every
# allowlist. hexpm for the Elixir repos, cratesio for the Rust ones.
config :custode,
  external_mcp_servers: [
    %{name: "hexpm", type: :http, url: "https://hexpm-mcp.fly.dev/mcp"},
    %{name: "cratesio", type: :http, url: "https://cratesio-mcp.fly.dev/"}
  ]

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

# Cron schedules run in THIS timezone (#17): "@daily" means local midnight,
# not 5pm-the-previous-day. Sensors on */N cadences are unaffected.
config :custode, timezone: "America/Los_Angeles"
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

import_config "#{config_env()}.exs"
