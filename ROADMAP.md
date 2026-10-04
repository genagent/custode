# Roadmap

Open work is tracked in
[GitHub issues](https://github.com/genagent/custode/issues), and #599 is the
backlog index. The last plan was
[design/010-back-to-the-dashboard.md](design/010-back-to-the-dashboard.md),
tracked by #453, which closed on 2026-09-24 once rungs 0 to 4 had shipped.
This file keeps the current status, the standing architectural positions, the
rungs, and the shipped-milestone history.

## Status: public operator alpha (2026-10-04)

Custode v0.3.0 is the current source-installed release. Since v0.2.2, it adds
durable peer requests and replies, a continuing project-manager conversation
at `/custode`, and early provider session recovery after an interrupted turn.
The daily-use UI now has clearer attention actions and counts, comparable
metrics charts, compact digests, accessible controls, and consistent ordinary
page headers. Failed workflows show their recorded stopping stage and retain
successful results; safe retry remains open under #750.

The manager reads current project evidence and coordinates authorized work
through existing roles and gates. Direct project conversations remain
available. Peer receipt is not work completion, and a provider session handle
is not durable project context. The design/013 spike in #700 remains separate
from the dashboard and fleet product.

To upgrade a running v0.2.2 installation:

1. Drain Custode and wait for the process to exit before updating the live
   checkout.
2. Update the checkout, fetch the released dependencies with `mix deps.get`,
   and run `mix custode doctor`. Review the pending peer-message migration
   and resolve unrelated preflight failures.
3. Take a recoverable backup of `CUSTODE_HOME`, run `mix ecto.migrate`, and run
   doctor again. The new migration is
   `20261004034345_create_peer_messages.exs`; older installations must review
   all their pending migrations.
4. Inspect any required operator-skill refresh, then restart to load the
   revised caretaker prompt and MCP surface. Reload the regenerated operator
   token and restart or reconnect provider clients. The
   [install guide](guides/install.md#upgrading-from-v022-to-v030) has the
   operating note and complete update procedure.
5. Continue from #599. Decisions #554 and #555 remain operator-held. The
   work kernel remains frozen under design/010.

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
| 3 | custode as the operator's right hand | done: the continuing manager conversation and project evidence reads (#451), durable peer requests and replies (#461), and cross-provider gate review (#522). Existing human approval and spend rules remain in force |
| 4 | A routine can run on Codex | done (#452, #522, #523) |
| later | Missions (#459) | design only |

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
- 2026-10-04: v0.2.2 updates the MCP transport to Snodo 0.4.1 and verifies
  resource-template compatibility and current-protocol client reads.
- 2026-10-04: v0.3.0 adds durable peer messaging (#461), the continuing
  project manager (#451), and early native session recovery (#708). The
  daily-use UI work (#743 through #749 and #751) improves digest and chart
  reading, attention clarity, shared controls, and page structure. #765 adds
  recorded workflow failure display; safe retry stays open under #750. The
  release includes the peer-message migration and revised caretaker prompt.
