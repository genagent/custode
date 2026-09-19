# 010: Back to the dashboard

Status: direction note, agreed with the operator on 2026-09-19. It suspends
the migration direction of design/008 and narrows design/009. Neither is
retired: 008 remains the account of the kernel as built, and 009's benchmark
(does it beat the dumb routine on delivery) is the test for ever resuming it.
Tracking issue: #453.

## Context

The fleet last ran a real agent turn on 2026-08-03. It was booted once more,
2026-09-14 to 2026-09-17, and ran zero turns: the boot doctor failed because
the `claude` CLI was logged out, ticks were withheld, sensors kept firing,
and no surface said so (#443). The operator saw a fleet that "seemed stuck"
and stopped.

Between 2026-08-01 and 2026-09-19 the operator built about eight fresh takes
on the same idea in other repositories (ciacola, tuto, testa, roba, scavo,
solito, agent-sessions, agent-mcp), roughly 700 commits. Each re-derived the
four components design/009 says earned their keep: ledger, switchboard,
scheduler, workspace bookkeeping. None became a daily driver. custode is the
one that ran a fleet for weeks: 100 to 267 turns a day in late July, 467
resolved gates, 1,861 spend rows.

The operator's statement of the product, from the same conversation: a
dashboard of agents I can both interact with and that keep working on a
schedule. A CLI or REPL is good for one thing at a time and poor at three
things that matter here: seeing many things at once, input, and surfacing
what needs attention.

Standing goals, unchanged: (a) many agents working and pinging the operator
when they need something; (b) autonomous cross-provider work, Claude and
Codex together.

## Decisions

### 1. No restart

The three things the operator would change in a rewrite are reachable from
here:

| If starting over | State in custode |
|---|---|
| MCP from the start | 72 tools and 17 resources exist; every `mix custode` subcommand but `doctor` is one MCP call. The gap is a finite list of operator verbs. |
| A nicer UI on daisyUI and LiveView | Already daisyUI 5 on LiveView. The design work is done and was never implemented (`design/ui/`). |
| Topics, not agents | The roster is 11 repositories with one agent each. A topic is a routine today. It needs a name before it needs a table. |

### 2. The work kernel is frozen, not deleted

| Measure | Value |
|---|---|
| Kernel share of `lib/` | about 25.7k of 52.8k lines |
| Kernel share of migrations | 13 of 30 |
| Attempts ever run | 2 |
| Head-to-head on one issue (#425) | the routine path shipped #427; the kernel Attempt blocked |

How: `github_issue_intake_pilots` goes empty.
`GitHubIssueIntake.on_routine_tick/1` returns `:noop` when a routine has no
pilot, so `RoutineTick` inserts the legacy tick and nothing else happens. The
boot reconcilers and the lease `ReconcileJob` keep running and are harmless.

Deleting the kernel is weeks of work against a live database and is still
working on the system instead of using it. 009 already authorizes deletion
when a fix touches kernel code. That stays the rule.

Consequences:

- The routine path is the product. 008's plan to retire it is suspended.
- WorkItem 9732e9c3 stays parked at `blocked/implementing`. #439 remains
  true and has no operational effect while frozen.
- #422, #423 and #424 stay open and unscheduled.
- `work_gates` gets no operator surface. It is only worth building if the
  kernel resumes.

### 3. The UI is the one layer where a clean slate is sanctioned

`lib/custode_web` is 4,650 lines. The console (#450) is built beside the
existing pages, and the old pages are deleted when it covers them.

### 4. Surfaces stay thin

A LiveView `handle_event` calls a shared operation function and contains no
business logic, the pattern #382 started with pause. If the modules are
right, MCP is a thin layer over them and parity costs little whenever it is
wanted. This is the one rule kept from the MCP-everywhere discussion.

### 5. Session mining stays a separate project

solito, agent-sessions and scavo explore a different problem: the session as
substrate and the topic as what the user returns to, with compaction and
cross-agent context handled by a library. custode's turns are hermetic and
its memory lives in files and GitHub, so it does not have that problem.

## The rungs

Each rung is used before the next begins.

### Rung 0: running again

Operator actions: `claude login`; cancel the 704 stale queued ticks (#442);
set an ntfy topic so the push channel that is already built starts working;
review #437 and #427; close #440.

PRs: this note and the design import; the freeze and the `artifacts/` ignore
rule; the 2026-09-14 lockfile bump; #442.

### Rung 1: attention that cannot be missed

The resolver of design/007 is sound. Several human-owed states never reach
it.

| Finding | Issue |
|---|---|
| A failed doctor is a red badge on an unlinked page and nothing else | #443 |
| A sensor failing every run is drawn as ambient grey (`ci-redisctl`, SAML, since 2026-09-14) | #444 |
| `ask_operator` writes a row and notifies nobody | #445 |
| The only escalation for an aging gate is a prompt asking the caretaker to remember (worst gate: 13.5 h) | #446 |
| Workflow proposals, workflow budget pauses and draft batches never reach the inbox | #447 |
| A gate records `resolved`, not approved or rejected | #448 |
| "Re-run checks" is offered in three signals and handled nowhere | #449 |
| Dashboard rejections carry no reason | #438 |

### Rung 2: the console

`design/ui/2026-07-25-design-session/figures/console.png`. A rail of every
subject grouped by the resolver, a subject pane with tabs and a message box
that is always present, an item pane whose buttons are the signal's own
`resolving` ops. #450 lists the input gaps it closes.

### Rung 3: the right hand

`figures/custode-root.png`: root, sees everything, speaks for the operator.
The operator wants custode able to manage, reconfigure and delegate, to the
point that individual agents rarely need direct attention.

Today the caretaker can edit the roster and profiles, pause and resume, and
delegate. It is refused sibling gates and asks, is granted none of the
operator's read tools, and its prompt forbids deciding a sibling's gate.

This rung amends design/000, which makes the operator the sole approver. The
amendment is written when the rung is reached. Open questions are in #451:
which gate classes custode may decide alone, on what evidence (#448 is the
prerequisite), what stays mechanical regardless, and how an action is undone.

MCP parity is pulled by this rung, not pushed as a program. The verbs custode
lacks are the operator verbs missing from MCP.

### Rung 4: Codex

A routine cannot run on Codex: the provider is not a field, and about 25
call sites name `ObanClaude.Agent` directly. `oban_codex` mirrors the Agent
lifecycle file for file. The work is a facade, a `provider` field, and a
token-denominated rail, because Codex reports no cost. First user: a Codex
reviewer on Claude-authored PRs. #452.

## Deferred, with what is already known

Kept so a later session does not re-derive it. All from the 2026-09-19 audit.

**MCP parity as a program.** Dashboard-only or iex-only today: pause all and
resume all, aborting a timed-out drain, doctor, journal reads, applying or
dismissing a suggestion, workflow launch, approve and resume, panel approve,
reject and revert, draft drop and keep. No push channel: anubis supports
resource subscriptions and custode never sets `subscribe?`.

**Headless.** The Endpoint child is unconditional in `application.ex` and
`custode.toml [server]` has no key to disable it.

**Remote.** The MCP bind IP is hardcoded (`application.ex`, Bandit
`ip: {127, 0, 0, 1}`). `cli/client.ex` hardcodes `127.0.0.1` and honors only
a port variable. There is no release, the two engine deps are path deps, and
every repo-tied routine has a `/Users/...` `working_dir` with no provisioning
step. `mix custode` needs a Mix checkout on the operator's machine; a generic
MCP client such as mcp-repl does not.

**Before any listener leaves loopback.** Most write tools have no
server-side identity check and rely on the agent's client-side allowlist.
`Custode.MCP.caller/1` falls back to the operator identity for a frame with
no assign. `secret_key_base` is a checked-in value. `pause_agent` is
authorization-checked and `resume_agent` is not.

**A topics table.** Reopen when one topic needs two workers, which rung 4
may produce.

**Kernel deletion.** Opportunistic, per 009.

## Relationship to other documents

- design/000 remains the canonical operator model. Rung 3 will amend its
  sole-approver rule when reached.
- design/007 is the contract the console is built on. No surface re-derives
  attention.
- design/008 remains authoritative for the kernel as built. Its migration
  sequencing is suspended by decision 2.
- design/009's four components and its benchmark stand. Its task-queue
  direction is not pursued while the routine path is the product.
