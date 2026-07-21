# Roadmap

Open work is tracked in
[GitHub issues](https://github.com/genagent/custode/issues) (migrated
2026-07-21; labels: security, durability, ux, agents, cost). This file keeps
the standing architectural positions and the shipped-milestone history.

## Standing architectural notes

- The core engine is `ObanClaude.Agent` (oban_claude >= 0.4.0). custode is
  the application layer: routines, notebook, memory, spend/budgets, gates,
  sensors-to-be, MCP surface, dashboard. Operational features belong here,
  not in the engine.
- Extraction trigger for the agent layer out of oban_claude: the first HARD
  dep the seam should not carry. Optional deps do not count.
- The dashboard's eventual form is a mountable component (Oban.Web-style);
  the LiveViews stay thin over the facade to keep that extraction mechanical.
- Verbs over workflows: agents get reliable predefined tools (gh_ex /
  git_wrapper_ex wrapped as MCP tools) rather than enforced step order.
- Cheap sensor, expensive brain: mechanical ticks detect change and drop
  inbox notes; LLM turns run to judge, not to poll.

## Shipped milestones

- 2026-07-20: agent lifecycle spike -> oban_claude 0.4.0 (published);
  custode demo app: routines (crontab-as-agent-spec), notebook + memory
  (tool-mediated, zero standing write permission), spend ledger with
  auto-pause budgets, durable gates with restart notices, MCP
  agents-driving-agents (two capability tiers), LiveView dashboard.
- 2026-07-20: custode-dev merged its first two changes to this repo (feed
  rotation; the OBAN_CLAUDE_PATH worktree override), each human-reviewed.
- 2026-07-21: tile-grid fleet UI with per-agent detail pages and
  attention-first sorting; fleet expansion (redis-tower + git-spawn backlog
  workers on opus, star tracker, contributor watch) with baselines
  live-verified; click-through desktop notifications.
