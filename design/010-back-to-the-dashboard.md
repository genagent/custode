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

PRs, in merge order: #455 first, because `main` had failed `mix test` on
every date since 2026-08-25 and nothing reported it (#454: a cost window
measured from the wall clock behind an injected `:now`; CI last ran on `main`
on 2026-08-01). Then this note and the design import (#441), the freeze and
the `artifacts/` ignore rule (#456), the 2026-09-14 lockfile bump with `mint`
taken to its patched version (#457), and a fix for #442.

Found along the way and not scheduled: `earmark` is retired and carries an
unpatched XSS advisory. Agent markdown renders through it behind a pre-escape
(#460).

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

Dollars are not the headline number. The operator is on Max plans: cost and
tokens are worth recording, and what they want to see is usage percentage
against the plan's limits. `Custode.Availability` (#393) already has
collectors for Claude and Codex, a snapshot with per-bucket utilization and
reset times, and freshness rules. No code in `lib/` calls a collector. #458
wires them and puts utilization where the dollar figure is today. The dollar
rails stay as the runaway guard.

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

### Later: the agent mesh

The operator's framing: very often one project needs something from another.
Filing an issue on the other repository and letting its agent pick it up is
usually the right move, and sometimes direct communication would be faster.
Both should exist, Claude to Codex included, and the mesh is the goal. #461.

The delivery mechanism exists and is provider-blind: `Custode.Inbox.drop/3`
writes a note and schedules a tick, and neither step knows what runs the
recipient. The constraint that shapes the design is the charter's rule that a
note is an event and never a command. A message from a sibling is evidence
and a request; the recipient still proposes its own gated action, and the
permission tree gains no sideways edge.

### Later: missions

The operator's definition: this project should take on a specific large
task, self-organize workers, delegate and track the work. They want to
emphasize it once the pivots above are in use, and not before. #459 holds the
idea and what it would stand on: the frozen kernel's Mission tables, the
workflow runner, sub-agents, the mission mockups in `design/ui/`, and the
reopen trigger on crews (#421), which a mission is. It depends on rung 3,
because something has to stand up a mission's workers and answer for them.

## Progress

Kept current as rungs land. The tracking issue (#453) has the checklist.

**2026-09-19.** Rung 0's code and all of rung 1 except #447 merged in one day,
plus a first slice of rung 2.

| Rung | Landed |
|---|---|
| 0 | #455 (`main` had been red since 2026-08-25), #456 (the freeze), #457 (lockfile, `mint` CVE), #462 (stale ticks are discarded, so the 704 queued jobs need no manual cleanup) |
| 1 | #463 doctor signal and banner, #464 asks notify, #465 gate outcomes, #466 the dead "Re-run checks" op, #467 reject reasons, #468 failing sensors, #469 mechanical re-notify |
| 2 | #470 the console's first slice at `/console`, #473 operator prompts reach a paused or offline agent |

Three things learned that change later rungs:

1. **The operator approves 98% of gates**: 351 approved, 7 rejected, nine
   agents at 100% (#465 put the outcome on the gate row; the history was
   recoverable from feed entries). Against a median wait of 5.9 minutes and a
   worst of 13.5 hours, most gates are a formality that costs wall-clock time.
   That is the evidence rung 3 asked for. Its limit: the rate is per agent,
   not per gate class, because a gate's class is free prose. A class field is
   the prerequisite for letting custode decide some classes and escalate
   others.
2. **The engine drops a prompt cast at a paused agent and errors for an
   offline one.** The agent page hid its composer because of it, and `mix
   custode prompt` reported success while the text was discarded.
   `Custode.Operator.Actions.message/3` resumes a paused agent first and
   starts an offline routine with the message as its turn, and says which it
   did. No operator surface should call `cast_prompt/3` directly.
3. **Decision 4 has a home.** `Custode.Operator.Actions` is the module a
   surface's handlers call. Its `run/4` takes the op atoms from a signal's
   `resolving` list, so a surface renders a signal's own buttons and hands
   the click back. The console is built on it; the older pages are not yet.

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
