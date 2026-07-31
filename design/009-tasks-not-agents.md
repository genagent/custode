# 009: Tasks, not agents

Status: direction note. This records a set of claims agreed with the operator
on 2026-07-30, the evidence behind them, and what they imply for how custode
evolves. It does not supersede design/008, which remains authoritative for the
work-first kernel as built. It does constrain what gets built next: the
standing decision from the same conversation is fix and delete, do not extend,
until the golden vertical is boring.

## Context

This note was written the evening the golden vertical ran for the first time
(#354, WorkItem 9732e9c3, issue #425). Two facts from that run frame
everything below:

1. The kernel executed the full vertical correctly and the model produced the
   correct diff, then blocked at `implementing` because the issue's acceptance
   prose contradicted the phase's tool allowlist (#428). Every typed safeguard
   held; the failure entered through a field no safeguard inspects.
2. Seven minutes after the kernel blocked, the legacy `custode-dev` routine
   opened PR #427 for the same issue with a byte-identical diff, green on all
   checks. On the one piece of work both paths were ever pointed at, the path
   the kernel is meant to replace delivered and the kernel did not.

The operator's question that prompted this note: is the system too big for its
own good? The answer arrived as: the kernel is not too big, the ratio of
machinery to exercised machinery is off. `attempts` was zero for the kernel's
entire life while all 33 checklist boxes of design/008 shipped. Most of what
exists defends against failure modes that have never occurred in this
deployment shape: one laptop, one human, one SQLite file, one writer.

## The baseline, stated honestly

A pile of `claude` CLI sessions in tmux, or the desktop app, already provides:
the agent loop, interactive steering, per-session transcripts, parallelism,
worktree isolation, and per-action permission prompts. The executor is a
commodity and improves without us. The kernel Attempt and the legacy routine
producing byte-identical diffs is the proof: nothing we build makes the agent
smarter.

What that baseline lacks, and what custode's own evidence says earned its
keep, is exactly four things:

| Component | What it is | Evidence |
|---|---|---|
| Ledger | Durable, queryable record: what ran, what it cost, what it produced, why it stopped | A cold session went from "it's stuck" to a file-and-line root cause in ~15 minutes because the typed timeline and frozen `error_details` existed |
| Switchboard | One queue for everything needing the human, blocking (gates) distinguished from non-blocking (asks) | Gate latency median 5.9 min, worst 13.5h, 71 gates over an hour: operator attention is the system bottleneck. Asks exist because an agent once idled 67 minutes on an invisible question |
| Scheduler | Initiative: cron, sensors, sweeps | Running for weeks; the sensor doctrine (cheap sensor, expensive brain) holds |
| Workspace bookkeeping | Worktree ownership and reclamation | Real but thin; git worktrees do most of it (#430 shows the reclamation half was never even wired to a clock) |

Everything else custode carries is either the product surface over those four
(feed, status, dashboard) or kernel machinery built for hazards this
deployment shape does not have (concurrent writers, adversarial replays,
mid-flight policy edits racing in-flight work).

## The four claims

### 1. The problem is a task queue, not a swarm

design/008 already moved halfway here: WorkItem owns the outcome, Attempt
performs bounded work. Attempts are jobs. Turns are hermetic; nothing
conversational survives between them; memory lives in files and GitHub. The
persistent "agent" is a fiction layered on jobs: a cron entry plus a prompt
plus an allowlist wearing a name.

The fiction has a cost. The roster is 11 repositories with 11 mostly-idle
identities. #421 (crews) died because the argument rested on a routine that
no longer existed. The kernel kept the whole agent apparatus (roles,
bindings, missions, personas) alongside the task model, so both are paid for.

"Agent" conflates three things that a task model separates cleanly:

- identity (who): becomes a fungible worker pool
- capability (what it may do): becomes a field in the job package
- context (what it knows): becomes a field in the job package

What must survive the collapse: the tier/grant permission model. It
translates directly, and arguably more legibly, into which job kinds may
enqueue which job kinds, and which require gates.

### 2. The triad is the primary surface: done, doing, planned

Being able to reason mechanically about what happened, what is happening, and
what is planned is the product. This day was a controlled experiment on it:
the machine-written past (work_events, error_details) was correct and made a
cold diagnosis fast; the hand-written present (a CLAUDE.md "the fleet is
RUNNING" note) was wrong twice while the node sat dead for four hours.
Machine-queryable beats prose for all three tenses.

Custode has all three today, scattered across representations: past in
`feed.jsonl` and work_events, present in process state, future in GitHub
issues. The direction is not new stores. It is making the triad the primary
read surface, one query each, and making every consumer (retro advisor,
attention, `mix custode status`, the meta job below) a reader of the same
three views. The feedback loop stops being a feature and becomes the schema.

The future store specifically is GitHub issues and stays that way, per the
standing GitHub-as-brain doctrine. The planned view is a projection, not a
table.

### 3. Workers are a pool; context arrives in the job package

Instead of an agent per repo per concern, a pool of interchangeable workers.
A worker gets a job package containing everything the turn needs: objective,
acceptance criteria appropriate to the phase (#428 is what happens
otherwise), compiled context, tool capabilities, budget, output contract.

This is ContextBundles, generalized, and it is the part of the kernel the one
real run validated end to end: the bundle compiled in milliseconds, the
digest pinned, and a worker with no name and no history produced the correct
change. The packaging idea worked; the failure was inside one field's prose.

Two consequences to hold onto:

- The pool's effective concurrency is bounded by operator attention, not
  compute. The gate-latency numbers put honest N at about three.
- Context compilation is now where the intelligence lives. The hard problem
  moves from "what does the agent do" to "who writes the package", which is
  the next claim.

### 4. Three job shapes: continuous, ad hoc, meta

- Continuous: cron-driven, standing scope. "Work the backlog for repo X" is a
  dispatcher job: read the backlog, pick one item, compile a package, enqueue.
- Ad hoc: started with a prompt by the operator.
- Meta: a scheduled job that reads the triad, checks for issues, reports
  status, and writes new items to the plan.

The meta shape dissolves custode-the-caretaker from a resident singleton
process into a recurring task that operates on the queue through the queue.
It is distinguished only by what it reads (all three views) and what it may
enqueue, not by being a different kind of thing. Sensors fit unchanged: a
sensor is a cheap continuous job whose output is an enqueue with evidence.

The trap this taxonomy names: agent-per-repo hid the task-decomposition
problem, because "the agent figures out what to do" was the design. A task
queue makes someone responsible for writing tasks. That someone is the meta
job, the sensors, and the operator. The intelligence did not disappear; it
moved from the workers to the task-writers. Design effort belongs there.

## The shape has a name

Fungible runners, self-contained job specs, a queue, cron triggers, manual
dispatch, and a scheduler watching the board: this is a build farm. GitHub
Actions has this architecture. It is one of the most battle-tested shapes in
software, which counts in its favor. "Agent orchestration" here is job
orchestration where the job body happens to be an LLM turn.

And custode already sits on this substrate. Oban is a task queue with cron,
retries, states, uniqueness, and a persisted job table. Parts of the kernel
reimplement Oban semantics one layer up. The four claims together read less
like a redesign than like removing a layer between the product and the
substrate. The deltas worth owning are:

- the job package compiler (ContextBundles, kept)
- the three triad views (projections, mostly over existing records)
- the switchboard (gates as a job state, asks as notes; kept)
- the meta job (a rewrite of the caretaker as a scheduled task)

Everything else is Oban plus the `claude` CLI plus git worktrees.

## What this note does and does not authorize

Does not authorize: a rewrite, a migration epic, or new kernel tables. The
standing decision is the opposite: run the vertical until it is boring, fix
and delete, and let repetition generate the findings (the first run produced
three issues in one day: #428, #429, #430).

Does authorize, when each becomes the natural next step rather than a
program:

- Preferring deletions that collapse agent-shaped machinery into job fields
  when a fix touches that machinery anyway.
- Building any new read surface as one of the three triad views rather than a
  bespoke screen. #423 and #424 (operations catalog, operation log) are
  already shaped this way.
- Evaluating any future kernel work against one benchmark: does it beat the
  dumb routine on delivery. #427 versus the blocked Attempt is the standing
  example, permanently in the record.

## Relationship to other documents

- design/000 remains the canonical operator model. Nothing here changes the
  operator -> custode -> specialists -> sub_agents authority tree; it changes
  what the middle two layers are made of.
- design/008 remains authoritative for the kernel as built and still governs
  where it supersedes earlier records. This note is a direction for what gets
  built or deleted next, not a replacement account of what exists.
- repol is this note's conclusion applied from scratch: one repo, one human,
  gates, a meta agent, an MCP-only surface, no kernel. custode informed that
  shape; this note is custode absorbing the lesson back.
