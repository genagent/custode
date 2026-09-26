# Roadmap

Open work is tracked in
[GitHub issues](https://github.com/genagent/custode/issues), and #599 is the
backlog index. The last plan was
[design/010-back-to-the-dashboard.md](design/010-back-to-the-dashboard.md),
tracked by #453, which closed on 2026-09-24 once rungs 0 to 4 had shipped.
This file keeps the current status, the standing architectural positions, the
rungs, and the shipped-milestone history.

## Status: paused (2026-09-26)

Work on custode is paused. The last release is v0.1.0 (2026-09-24), and
`main` carries fixes after it through #698. No issue is claimed. The only
open pull request is #700, the design/013 spike, which is not merged and waits
on the operator. Its ideas continue as a separate, standalone project; custode
stays as it is so work can resume here.

To resume:

1. In the checkout the fleet runs from, `git pull`, then `mix deps.get`.
   `mcp_ex_plug` comes from the private `joshrotenberg/mcp_ex` repository at
   a pinned commit, so it needs SSH access to it or `MCP_EX_PATH`. That
   library is being reworked and renamed. The pinned commit keeps resolving
   through GitHub's rename redirect; moving the pin will need the new package
   and module names.
2. `mix custode doctor`, then `mix phx.server`. A normal boot schedules
   every routine in the local `routines.toml` on its cron, and `@reboot`
   routines fire once. For a quiet start, use "pause all" in the console
   header's fleet menu as soon as the node is up, then resume routines one at
   a time with `mix custode resume <agent_id>`.
3. GitHub Actions has not run since 2026-09-24: every job fails before its
   first step because the account's Actions spending limit is exhausted.
   Merges since then rest on the five local gates in AGENTS.md. Check that CI
   runs again before relying on it.
4. Pick up from #599. #554 and #555 are the operator's decisions, #499 and
   #556 are blocked, and the work kernel stays frozen (#423, #424, #439,
   #630).

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
| 2 | The console | done: it is the home page (#450, #552, #594) |
| 3 | custode as the operator's right hand | mechanisms merged: gates record class and risk, grants bound an approved turn (observe mode), `/custode`, a cross-provider review on gates (#522). Left for the operator: #554, #555. The design stays open as #451 |
| 4 | A routine can run on Codex | done (#452, #522, #523) |
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
- 2026-09-21 to 2026-09-24: Codex routines (#452), cross-provider gate
  review (#522) and portable handoff context (#523); the HTTP transport moved
  to mcp_ex; MCP identity and authority enforced at the endpoints, with a
  written authorization matrix; routine-owned checkouts that custode
  provisions and refreshes; guided agent onboarding; conversation arcs and
  operator messages correlated with their outcomes; Claude plan usage read
  over OAuth; the wrapper packages consumed from Hex; recovery fixes for
  SQLite busy acknowledgements, durable gate decisions and the scheduler's
  beat handoff.
- 2026-09-24: v0.1.0, a private, source-installed, single-operator local
  alpha. [guides/demo.md](guides/demo.md) is its quickstart.
