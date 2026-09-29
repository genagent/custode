# Roadmap

Open work is tracked in
[GitHub issues](https://github.com/genagent/custode/issues), and #599 is the
backlog index. The last plan was
[design/010-back-to-the-dashboard.md](design/010-back-to-the-dashboard.md),
tracked by #453, which closed on 2026-09-24 once rungs 0 to 4 had shipped.
This file keeps the current status, the standing architectural positions, the
rungs, and the shipped-milestone history.

## Status: public operator alpha (2026-09-29)

Custode is public, GitHub Actions is live, and v0.2.1 is the current
source-installed release. It includes the v0.2.0 transport, fleet reliability,
and operator skill work, then adds a focused conversation view for every agent.
The view keeps operator prompts, provider replies, questions, approvals, and
outcomes together while preserving the full control-room view for fleet work.
The design/013 spike in #700 remains separate from the dashboard and fleet
product.

To upgrade a running v0.1.0 installation:

1. Drain Custode and wait for the process to exit. Do not update the live
   checkout while the old node is still running.
2. In that checkout, run `git pull --ff-only`, `mix deps.get`, then
   `mix custode doctor`. Fix every failure before applying schema changes.
3. Review the four migrations added since v0.1.0, take a recoverable backup of
   `CUSTODE_HOME`, then run `mix ecto.migrate` and `mix custode doctor` again.
4. Check each configured host with `mix custode.skill.install all` (or select
   that host explicitly). If it reports a stale or modified package, inspect
   the installed files before choosing the printed `--force` command. Restart
   Custode, refresh the operator token in the host environment, and restart or
   reconnect the host.
5. Pick up from #599. #554 and #555 are the operator's decisions, #499 and
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
  to Snodo; MCP identity and authority enforced at the endpoints, with a
  written authorization matrix; routine-owned checkouts that custode
  provisions and refreshes; guided agent onboarding; conversation arcs and
  operator messages correlated with their outcomes; Claude plan usage read
  over OAuth; the wrapper packages consumed from Hex; recovery fixes for
  SQLite busy acknowledgements, durable gate decisions and the scheduler's
  beat handoff.
- 2026-09-24: v0.1.0, a private, source-installed, single-operator local
  alpha. [guides/demo.md](guides/demo.md) is its quickstart.
- 2026-09-29: v0.2.0, the public source-installed operator alpha. Snodo is the
  packaged MCP transport; routine handoffs and queued wakes survive races;
  console text and navigation are easier to scan; and the installable operator
  skill teaches safe lifecycle, troubleshooting and self-maintenance across
  Claude Code and Codex.
- 2026-09-29: v0.2.1 adds a focused, full-height conversation view for every
  agent, with correlated exchanges, stable history pagination, shared drafts,
  inline questions and approvals, and live updates that preserve scroll
  position.
