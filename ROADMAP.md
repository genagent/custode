# Roadmap

Open work is tracked in
[GitHub issues](https://github.com/genagent/custode/issues). The plan is
[design/010-back-to-the-dashboard.md](design/010-back-to-the-dashboard.md),
tracked by #453. This file keeps the standing architectural positions, the
rungs, and the shipped-milestone history.

## Labels

Priority `p1` / `p2` / `p3`. Area: `area/ui`, `area/gates`, `area/fleet`,
`area/mcp`, `area/kernel`, `area/infra`. Status: `status/in-progress`,
`status/blocked`, `status/needs-review`. There is no type label: the
conventional-commit prefix in the title is the type
(`gh issue list --search "fix: in:title"`). `decide:` titles are waiting on
the operator.

## The rungs (design/010)

Each is used before the next starts.

| Rung | What | State |
|---|---|---|
| 0 | Running again | done |
| 1 | Attention that cannot be missed | done |
| 2 | The console | done: it is the home page. Display gaps on #450 |
| 3 | custode as the operator's right hand | in progress (#451): gates record class and risk, grants bound an approved turn, `/custode` exists. Next: a second opinion on the diff (#522), then the operator lists which classes custode may approve |
| 4 | A routine can run on Codex | not started (#452, #522, #523) |
| later | Agent mesh (#461), missions (#459) | design only |

Deferred by the operator: remote access, headless operation, MCP parity as a
program of its own. The work-first kernel (design/008) is frozen: in the
tree, not running, deleted only when a fix touches it.

## Standing architectural notes

- The core engine is `ObanClaude.Agent`. custode is the application layer:
  routines, notebook, memory, spend, gates, sensors, the MCP surface, the
  dashboard. Operational features belong here, not in the engine.
- `lib/custode/operator/` is where operator verbs and form rules live, one
  copy each. A surface's handler is one call into it. That is what keeps MCP
  a thin layer over the same modules.
- `Custode.Attention` is a pure resolver. No surface ranks anything.
- Policy narrows and never grants.
- Verbs over workflows: agents get reliable predefined tools rather than
  enforced step order.
- Cheap sensor, expensive brain: mechanical ticks detect change and drop
  inbox notes; LLM turns run to judge, not to poll.
- The fleet is local to a machine (`routines.toml`). Nothing
  machine-specific is checked in.

## Shipped milestones

- 2026-07-20: agent lifecycle spike -> oban_claude 0.4.0; the custode demo
  app: routines, notebook and memory, spend ledger with auto-pause budgets,
  durable gates, MCP agents-driving-agents, LiveView dashboard.
- 2026-07-21: tile-grid fleet UI, agent pages, the first fleet on real
  repositories.
- 2026-07-25 to 2026-07-30: the design session; the attention resolver
  (design/007); the work-first kernel (design/008), then the decision to stop
  building it.
- 2026-09-19: design/010, back to the dashboard. The kernel frozen, the fleet
  running again, stale ticks discarded at boot, the host doctor as a signal,
  gate outcomes recorded, reject reasons that teach, mechanical re-notify.
- 2026-09-19 to 2026-09-21: the console (now the home page), plan usage in
  the header, gate class, risk and grants, `/custode`, the paper and ink
  themes, suggested replies on asks, agent-set cadence, failure
  classification and backoff, rate-limit holds, the tool policy table,
  markdown through a sanitizing renderer, the roster made local.
