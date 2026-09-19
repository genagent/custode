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
      # Phase-split models: SURVEYS are cheap (sonnet, low effort -- find
      # one candidate and judge it), APPROVED IMPLEMENTATIONS are where
      # opus earns its tokens (via approved_args below). The ledger
      # records model per turn so the split's effect is measurable.
      model: "sonnet",
      effort: "low",
      max_budget_usd: 10.0,
      daily_budget_usd: 50.0,
      # implementation turns run cargo/mix suites; 15 minutes, not 200s
      timeout_ms: 900_000,
      # approved implementations iterate edit/build/test well past 20 turns
      max_turns: 75,
      tags: [:repo, :backlog],
      sensors: [:ci],
      # Local git reads stay Bash (workspace-local, harmless). The gh reads
      # are now scoped MCP read verbs (#129): repo_list_issues / repo_view_issue
      # / repo_list_prs / repo_view_pr / repo_pr_checks / repo_pr_diff, bound to
      # this routine's served repo -- so the unscoped `gh issue list` grants
      # (which let any routine read any repo) are gone.
      extra_allowed_tools: [
        "Bash(git log:*)",
        "Bash(git status:*)",
        "Bash(git diff:*)",
        "Bash(git show:*)"
      ],
      approved_args: %{
        "permission_mode" => "bypass_permissions",
        "worktree" => "custode-{id}",
        "model" => "opus",
        "effort" => "high"
      }
    },
    # The personal-learning tile (#119): an anki-esque tutor whose crontab
    # entry IS the spaced repetition. The notebook holds the deck; each run
    # reviews what is due and adds one new item; the operator's prompt-box
    # replies are graded answers. Non-repo, gate-free, tiny budget. Add one
    # with: id "italian", profile "tutor", prompt "Do your Italian tutoring
    # sweep now." -- the language rides the sweep prompt.
    tutor: %{
      cron: "@daily",
      prompt: "Do your tutoring sweep now (the language is in your standing orders or id).",
      role: :tutor,
      mcp: true,
      model: "sonnet",
      effort: "low",
      max_budget_usd: 0.5,
      daily_budget_usd: 2.0,
      timeout_ms: 200_000,
      max_turns: 15,
      tags: [:personal]
    },
    # The steward (design/006): a repo's groundskeeper. Where the backlog
    # worker drains a board, the steward FILLS one -- it runs the health
    # battery in-turn (cargo/mix by detection, real exit codes), judges what
    # is drifting, and files findings as `upkeep` issues via repo_open_issue.
    # @daily and cheap (mostly battery + one bounded judgment call); worker
    # and steward stay TWO routines per repo (pairing, not merging). Add one
    # with: id "<repo>-steward", profile "steward", repo/working_dir of the
    # served checkout.
    steward: %{
      cron: "@daily",
      prompt: "Do your stewardship sweep now.",
      role: :steward,
      mcp: true,
      model: "sonnet",
      effort: "low",
      max_budget_usd: 5.0,
      daily_budget_usd: 10.0,
      # the battery runs real suites (cargo test, mix dialyzer): 15 minutes
      timeout_ms: 900_000,
      max_turns: 40,
      tags: [:repo, :upkeep],
      sensors: [:ci]
    }
  },
  # P1 intake pilot (#366). This allowlist IS the operator approval design/008
  # asks for: a routine with an entry here has its beats drive the work
  # kernel's GitHub issue intake as well as its legacy tick.
  #
  # EMPTY ON PURPOSE since 2026-09-19 (design/010): the work kernel is frozen.
  # With no pilot, `GitHubIssueIntake.on_routine_tick/1` returns `:noop` and a
  # beat inserts the legacy tick and nothing else.
  #
  # History, so nobody repeats it: the pilot pointed at 368 until 2026-07-30,
  # and 368 had closed, so intake cancelled it at `discovered` every sweep and
  # the kernel observed nothing. It then pointed at 425, the first OPEN
  # subject, and on 2026-07-30 the vertical ran end to end and stopped at
  # `blocked/implementing` on a prose seam (#428, fixed by #432). That
  # WorkItem can never re-run and its issue can never get a second one (#439),
  # so resuming the kernel means a FRESH issue number here, never a retry:
  #
  #   "custode-dev" => %{
  #     repository_id: "1307868502",
  #     issue_numbers: [<an open, small, mechanical issue>],
  #     policy_version: "github-issue-intake-v1"
  #   }
  github_issue_intake_pilots: %{},
  routines: [
    %{
      id: "custode",
      # A sonnet sweep costs ~$0.40, so every minute is ~$25/hour -- the
      # default is a calm every-10-minutes. For an attended demo, flip to
      # "* * * * *" (or just drive beats by hand with Custode.beat()).
      # NIGHT WATCH (2026-07-21): */30 overnight; its job while unattended
      # is stale-gate escalation and stuck siblings, which half-hourly serves.
      cron: "*/30 * * * *",
      # The directory this agent tends. Relative paths resolve from the cwd.
      workspace: "workspace",
      tags: [:meta],
      role: :caretaker,
      prompt: "Do your caretaker sweep now.",
      # Fleet powers: this agent gets the custode MCP tools (run_job,
      # start_agent, ...) so it can delegate to one-shot jobs and sub-agents.
      mcp: true,
      # Provisioning pre-flight (learned setting up redisctl): checking a
      # repo's viewerPermission decides worker-vs-observer before any clone.
      extra_allowed_tools: ["Bash(gh repo view:*)"]
      # Other per-routine overrides:
      #   model: "haiku", max_budget_usd: 0.25, system_prompt: "..."
    },
    # custode working on custode (the ouroboros): a backlog worker against
    # custode's own issue queue, same loop as every other repo -- gh-driven
    # issue selection, one gated slice per sweep, approved implementations
    # in an isolated worktree behind CI and the review floor. CRANKED to
    # */15 (2026-07-21 night, operator-supervised queue): with #142's
    # dynamic scheduler this cadence is live-tunable from now on.
    %{
      id: "custode-dev",
      profile: :backlog_worker,
      cron: "*/15 * * * *",
      workspace: "dev-workspace",
      working_dir: ".",
      repo: "genagent/custode",
      tags: [:elixir]
    },
    # Backlog workers: slowly work through a repo's open issues -- at most one
    # proposed item per sweep, always human-gated, approved work in an
    # isolated worktree.
    %{
      id: "adrs",
      profile: :backlog_worker,
      # NIGHT WATCH (2026-07-21): sprint crank relaxed to half-hourly for
      # the unattended overnight run -- real backlog remains here, and the
      # operator works the gate queue on a wakeup loop. Restore @daily (or
      # let #124's cadence advisor decide) in the morning.
      cron: "*/30 * * * *",
      repo: "joshrotenberg/adrs",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/adrs",
      tags: [:rust, :external]
    },
    %{
      id: "redis-tower",
      profile: :backlog_worker,
      # NIGHT WATCH (2026-07-21): sprint crank relaxed to half-hourly for
      # the unattended overnight run -- real backlog remains here, and the
      # operator works the gate queue on a wakeup loop. Restore @daily (or
      # let #124's cadence advisor decide) in the morning.
      cron: "*/30 * * * *",
      repo: "joshrotenberg/redis-tower",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/redis-tower",
      tags: [:rust, :external]
    },
    %{
      id: "git-spawn",
      profile: :backlog_worker,
      # NIGHT WATCH (2026-07-21): sprint crank relaxed to half-hourly for
      # the unattended overnight run -- real backlog remains here, and the
      # operator works the gate queue on a wakeup loop. Restore @daily (or
      # let #124's cadence advisor decide) in the morning.
      cron: "*/30 * * * *",
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
      # NIGHT WATCH (2026-07-21): fully gated backlog -- every open issue is
      # milestone-gated, in review, or held for the operator (#937). */10
      # was pure no-op spend ($5+ today announcing nothing to propose);
      # @daily until the board changes.
      cron: "@daily",
      repo: "joshrotenberg/tower-mcp",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/tower-mcp",
      tags: [:rust, :external]
    },
    %{
      id: "tower-resilience",
      profile: :backlog_worker,
      # NIGHT WATCH (2026-07-21): sprint crank relaxed to half-hourly for
      # the unattended overnight run -- real backlog remains here, and the
      # operator works the gate queue on a wakeup loop. Restore @daily (or
      # let #124's cadence advisor decide) in the morning.
      cron: "*/30 * * * *",
      repo: "joshrotenberg/tower-resilience",
      working_dir: "/Users/joshrotenberg/Code/github.com/joshrotenberg/tower-resilience",
      tags: [:rust, :external]
    },
    # redisctl: provisioned via the caretaker's own recipe (2026-07-21
    # evening) -- it checked access, gated the clone move to the convention
    # path, and drafted this entry for the operator to land. @daily from
    # the profile; manual beats while onboarding.
    %{
      id: "redisctl",
      profile: :backlog_worker,
      repo: "redis/redisctl",
      working_dir: "/Users/joshrotenberg/Code/github.com/redis/redisctl",
      tags: [:rust, :external]
    },
    # The reviewer (#86 rung 3): reads siblings' ready PRs and posts gated
    # review: verdicts; a needs-human verdict mechanically blocks merging.
    %{
      id: "reviewer",
      cron: "@daily",
      workspace: "workspaces/reviewer",
      tags: [:repo, :watch],
      prompt: "Do your review sweep now.",
      role: :reviewer,
      mcp: true,
      model: "opus",
      max_budget_usd: 5.0,
      daily_budget_usd: 15.0,
      # reviews read whole diffs plus issue context and post through a gated
      # verb: the sweep default (20 turns / 200s) starved it twice on
      # 2026-07-22 (max_turns_exceeded reviewing a two-PR queue)
      max_turns: 50,
      timeout_ms: 600_000,
      # verdicts post through repo_review_pr (MCP): no shell elevation
      approved_args: %{},
      extra_allowed_tools: [
        "Bash(gh pr list:*)",
        "Bash(gh pr view:*)",
        "Bash(gh pr diff:*)",
        "Bash(gh pr checks:*)",
        "Bash(gh issue view:*)"
      ]
    },
    # The consistency auditor (#12): weekly cross-repo drift comparison,
    # one cohort per sweep, one gated alignment proposal at most.
    %{
      id: "consistency",
      cron: "@weekly",
      workspace: "workspaces/consistency",
      tags: [:watch],
      prompt: "Do your consistency sweep now.",
      role: :consistency_auditor,
      mcp: true,
      model: "opus",
      max_budget_usd: 5.0,
      daily_budget_usd: 10.0,
      extra_allowed_tools: [
        "Bash(gh repo view:*)",
        "Bash(gh workflow list:*)",
        "Bash(gh workflow view:*)",
        "Bash(gh release list:*)",
        "Bash(gh pr list:*)",
        "Bash(gh issue list:*)"
      ]
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
  # The default rail a workflow run carries (#271, design/005): a deep dig is
  # many nodes deep and can fan out wider than the launch estimate could know,
  # so it gets its OWN ceiling on top of the per-node cap. Crossing it parks
  # the run at budget_paused with a note naming what it did not run; letting it
  # go on is a human override. The launch gate quotes this and can override it.
  workflow_budget_usd: 20.0,
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

# One-way Mission mapping declarations for legacy routines without a single
# repository target. Repository routines resolve through GitHub's stable
# repository ID instead. These declarations describe scope only; routines.toml
# remains authoritative for schedule and executor fields.
config :custode,
  legacy_mission_mappings: %{
    "custode" => %{
      strategy: "fixed_mission",
      mission: %{
        key: "system:custode",
        purpose: "Operate Custode",
        lifecycle: "persistent",
        targets: [
          %{kind: "system", external_id: "custode", display_name: "Custode"}
        ]
      }
    },
    "quakes" => %{
      strategy: "fixed_mission",
      mission: %{
        key: "watch:usgs-earthquakes",
        purpose: "Monitor significant USGS earthquakes",
        lifecycle: "persistent",
        targets: [
          %{
            kind: "usgs_feed",
            external_id: "earthquakes-m4.5-day",
            display_name: "USGS M4.5+ earthquakes"
          }
        ]
      }
    },
    "stars" => %{
      strategy: "fixed_mission",
      mission: %{
        key: "observation:github-stars",
        purpose: "Observe GitHub star changes",
        lifecycle: "persistent",
        targets: [
          %{
            kind: "github_owner_set",
            external_id: "genagent+joshrotenberg",
            display_name: "genagent and joshrotenberg stars"
          }
        ]
      }
    },
    "contributors" => %{
      strategy: "fixed_mission",
      mission: %{
        key: "observation:github-contributors",
        purpose: "Observe GitHub contributor activity",
        lifecycle: "persistent",
        targets: [
          %{
            kind: "github_owner_set",
            external_id: "genagent+joshrotenberg",
            display_name: "genagent and joshrotenberg contributors"
          }
        ]
      }
    },
    "reviewer" => %{strategy: "repository_attempts"},
    "consistency" => %{strategy: "ephemeral_per_investigation"}
  }

# The fleet-tuning advisors (#125/#260): a name -> cron map naming which run
# and how often. `false` (or omitting a name) disables one. Toggleable via
# custode.toml's [advisors] section without a code edit. Cadence/Model/Budget
# are the zero-token deterministic trio; Retro (#262) is the weekly judgment
# advisor that reads the Digest. Dryness (#274) is deterministic too, but its
# output is a workflow launch GATE rather than a config suggestion -- it costs
# nothing to run and nothing until the operator approves the run.
config :custode,
  advisors: [
    cadence: "@daily",
    model: "@daily",
    budget: "@daily",
    retro: "@weekly",
    dryness: "@daily"
  ]

# Repo-owned ambient orders (#19): which routines may compose their
# working_dir's .custode/orders.md into the prompt. Scoped with the same
# selector language as the policies below. A file in a repo is prompt
# content, so this is opt-in by repo: genagent/custode is the fleet's own
# repository, where the operator owns every file that lands. Routines tagged
# :external never pick up orders regardless of what is listed here.
config :custode, ambient_orders: [repo: "genagent/custode"]

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
        "Conventional-commit style everywhere: commit messages, PR titles, " <>
          "branch names, AND issue titles (feat:/fix:/docs:/test:/chore:; " <>
          "branch prefixes to match). CI enforces commits and PR titles; " <>
          "issue titles are on you -- file them conventional, and treat a " <>
          "non-conventional title on an issue you touch as worth flagging."
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
