# 008: The work-first kernel -- Mission, WorkItem, Attempt, and Operation

Status: adopted for the incremental migration (2026-07-28)

This record is authoritative for the work-first migration. It resolves the
roster authority fork in #300, the durable work identity deferred in
design/007, and the control-plane seam exposed by the MCP survey in #345.

It does not replace the useful operational machinery already in Custode.
Routines, Oban, `ObanClaude`, typed repository verbs, workflows, gates,
attention, the feed, MCP, the CLI, and the current LiveViews remain in service
while the new records are introduced underneath them.

Where this record conflicts with earlier design notes, this record governs:

- design/000 remains the operational history and safety doctrine, but "the
  crontab entry is the agent" is no longer the durable identity of work, and
  GitHub comments are no longer the only lifecycle state after cutover;
- design/003 continues to govern binary layout and declarative assets, but
  live Missions, RoleBindings, WorkItems, and Attempts are database records;
- design/005 remains the durable workflow substrate, but a workflow run is an
  execution under a WorkItem, not the WorkItem itself;
- design/006's deterministic battery becomes a deterministic Attempt and
  evidence Artifact when that slice is migrated;
- design/007's decision to derive Attention stands, while its deferral of
  Missions and an operation registry is superseded.

## Decision

Custode adds a small work-first kernel underneath the current product:

> **Mission owns scope and continuity. WorkItem owns the outcome and
> lifecycle. RoleBinding lends capability. Attempt performs bounded work.
> Operation controls effects. Events and Artifacts preserve evidence.**

The following are settled:

1. Every WorkItem belongs to exactly one Mission.
2. A Mission may be persistent or ephemeral. That is lifecycle policy, not a
   different type.
3. WorkItem and Attempt are distinct. A failed Attempt does not make the
   WorkItem failed.
4. WorkItem state is generic. Workflow-specific progress belongs in `phase`.
5. `merge_ready` is a phase, never a canonical state.
6. A provider process or session does not own durable work.
7. Deterministic execution is an Attempt when it is bounded work intended to
   advance a WorkItem.
8. Oban owns dispatch, physical retry, and execution timing. WorkItem owns the
   meaning of outcomes and the next legal action.
9. Every state-changing actor path and every consequential external effect
   goes through the shared operation layer.
10. Board lanes, WorkItem states, phases, Oban queues, and executor capacity
    are separate concepts.
11. MCP, CLI, LiveView, workers, advisors, and caretaker become transports or
    actors over the same typed operations.
12. The migration is additive and reversible by slice. Existing routines and
    screens continue until the replacement path has run end to end.
13. Custode stays a modular monolith.
14. Custode remains repository-native, not repository-only. The first proof is
    GitHub issue to merge, but the kernel does not require a repository.

## Why this is the next seam

The checkout already has durable dispatch and recovery, bounded model turns,
durable workflow runs and results, typed repository reads and writes,
per-repository mutation serialization, gates, asks, derived attention, feed
history, and spend accounting.

The missing durable identity is the desired outcome. Today it is distributed
across routine configuration, GitHub marker comments, workflow runs, notebook
todos, gates, feed entries, and provider processes. Each of those remains
useful, but none can answer all of these questions:

- What outcome is Custode trying to achieve?
- Which policy and Mission authorized it?
- What phase is it in independent of a running process?
- Which executions tried to advance it?
- Which effects happened, under whose authority, and were they idempotent?
- What evidence makes it complete or blocked?
- What should happen after a restart or an external GitHub change?

The kernel supplies those answers without replacing the execution machinery.

## The domain model

### Mission

A Mission is the required durable scope for WorkItems.

It owns:

- a stable identity and human-readable purpose;
- lifecycle policy: persistent or ephemeral, active or archived;
- one or more typed targets;
- default policy and budget scope;
- context and knowledge scope;
- RoleBindings and Automation bindings;
- explicit relationships to other Missions when needed.

It does not own provider processes, Oban jobs, worktree implementation, every
integration row, or all policy details. It is a scope and continuity boundary,
not a container for the whole system.

Examples:

- persistent repository Mission: `genagent/custode`;
- persistent watch Mission: USGS earthquake monitoring;
- persistent system Mission: operating Custode;
- ephemeral Mission: one cross-repository consistency investigation;
- ephemeral Mission: an ad hoc objective that produces several WorkItems.

Every WorkItem has a non-null `mission_id`. An ad hoc request with no existing
scope creates an ephemeral Mission first.

An ephemeral Mission becomes archivable only when:

- all its WorkItems are terminal;
- no Gate, WorkspaceLease, Attempt, or OperationCall is active;
- its retention window has passed.

Archival is reversible policy state. History and Artifacts remain queryable.
Deletion is not the normal end of a Mission.

### WorkItem

A WorkItem is one durable desired outcome.

Its minimum contract is:

- required `mission_id`;
- optional parent WorkItem;
- work kind and workflow version;
- objective and explicit acceptance criteria;
- canonical state;
- workflow-specific phase;
- priority and policy reference;
- source and stable external key;
- monotonic version for optimistic concurrency;
- timestamps and completion or cancellation outcome.

For the GitHub vertical, the source key is stable across reconciliation:

```text
github:<github-repository-id>:issue:<issue-number>
```

The external repository ID is used instead of `owner/name` so a rename does
not mint duplicate work.

#### Canonical states

| State | Meaning |
| --- | --- |
| `proposed` | Known, but not admitted by current eligibility or policy. |
| `ready` | An allowed next action can be dispatched now. |
| `active` | A current Attempt or OperationCall is advancing it. |
| `waiting` | Progress depends on a known external event, timer, or Gate. |
| `blocked` | No allowed executable path is known without changed input, policy, or intervention. |
| `completed` | Acceptance criteria are satisfied and final effects are recorded. |
| `cancelled` | The desired outcome was intentionally abandoned. |

`failed` is not a WorkItem state. Attempts and OperationCalls fail. Policy
then moves the WorkItem to `ready`, `waiting`, `blocked`, `cancelled`, or
`completed` by another path.

`active` must name the current Attempt or OperationCall. A WorkItem may not be
left active merely because a process crashed. Reconciliation resolves the
execution and chooses the next state.

`waiting` names the expected wake-up condition. Waiting work consumes no
provider session and normally has no queued job.

`blocked` carries a structured reason and the class of changed input needed.
It is not a synonym for a failed command or a retry delay.

The generic transition floor is:

| From | Ordinary destinations |
| --- | --- |
| `proposed` | `ready`, `waiting`, `blocked`, `completed`, `cancelled` |
| `ready` | `active`, `waiting`, `blocked`, `completed`, `cancelled` |
| `active` | `ready`, `waiting`, `blocked`, `completed`, `cancelled` |
| `waiting` | `ready`, `blocked`, `completed`, `cancelled` |
| `blocked` | `proposed`, `ready`, `waiting`, `completed`, `cancelled` |
| `completed` | none |
| `cancelled` | none |

A terminal WorkItem may leave `completed` or `cancelled` only through an
explicit `work.reopen` operation with a reason and a new acceptance review.
External callbacks never reopen work implicitly.

The kernel validates the generic transition first. The versioned work-kind
module then validates the phase transition and its evidence.

#### State, phase, and lane

State answers whether work can run and what it is waiting on. Phase answers
where a particular workflow is. A board lane is a view over one or both.

Examples:

- `ready / implementation_ready`;
- `active / verifying`;
- `waiting / awaiting_review`;
- `waiting / merge_ready`;
- `blocked / repairing`;
- `completed / landed`.

`merge_ready` is `waiting` when a merge Gate is open. It may briefly be
`ready` before that Gate is created, but it never becomes a new canonical
state.

### Work kind and phase owner

Each WorkItem names a versioned work kind such as
`github_issue_to_merge@1`. Its module owns:

- the phase vocabulary and graph;
- admission and completion evidence;
- the next-command decision from current record plus a world snapshot;
- which transitions require a Gate;
- which external revisions make a proposed action stale;
- retry, repair, and terminal policy.

Models may propose a next action or return semantic findings. They do not
invent phases, write WorkItem state directly, or bypass transition
validation.

Changing a phase graph creates a new workflow version. Existing WorkItems
continue under the version they started with unless a typed migration
operation moves them.

### Attempt

An Attempt is one bounded execution intended to advance a WorkItem. It may be
model-backed or deterministic.

Minimum contract:

- required `work_item_id`;
- optional RoleBinding;
- executor kind, provider, profile, and recipe version;
- state;
- ContextBundle reference and digest;
- Oban job or workflow-run reference;
- opaque provider continuation;
- start and finish timestamps;
- usage and outcome summary;
- error classification;
- expected WorkItem version.

Attempt states are:

```text
queued
running
succeeded
partial
blocked
failed
cancelled
```

Only `queued` and `running` are nonterminal.

An Oban retry is another physical delivery of the same Attempt. It reuses the
Attempt ID and idempotency keys. Policy creates a new Attempt only when it
intends a new logical try, such as a focused semantic repair after
verification evidence.

Resuming semantic work normally creates a new Attempt. It may carry an opaque
provider continuation and a durable context delta, but provider session state
is never the only copy of progress.

A deterministic Attempt can run tests, prepare a workspace, compile context,
publish a branch, reconcile GitHub, or perform cleanup. This keeps evidence,
cost, retries, duration, and failure classification in one execution model.

### RoleTemplate and RoleBinding

A RoleTemplate is a reusable capability and execution definition:

- responsibility and intent;
- operation grants;
- recipe and prompt assets;
- default executor policy;
- default budget and limits.

A RoleBinding attaches one RoleTemplate to a Mission with scoped overrides. A
binding is not a permanent process. An Attempt records the binding that lent
its capability.

Product language may call bindings crew members such as `@lead`, `@reviewer`,
and `@triage`.

The current `Custode.Roles` entries, routine profiles, prompt stack, and tool
allowlists are compatibility inputs to RoleTemplates. Current routines become
legacy RoleBindings plus Automations; they are not renamed wholesale.

### OperationDefinition

An OperationDefinition is one typed control-plane capability. It declares:

- stable namespaced name, such as `github.merge_pr`;
- input and result schemas;
- query or command classification;
- risk class: `read`, `internal_write`, `external_write`, or `destructive`;
- required grants and current authorization adapter;
- idempotency contract;
- dry-run or effect-preview support;
- handler;
- audit rendering;
- MCP and generic UI projection metadata.

The first operation slice adds one dispatcher and envelope. It preserves
existing identity checks, repository policy, provider callbacks, and Gate
rules behind adapters. A complete grant language is not a prerequisite.

Private functions do not become operations merely to satisfy the registry.
High-volume reads may use the registry without a durable OperationCall.

### OperationCall

An OperationCall is one invocation of an OperationDefinition.

Its envelope carries:

- operation name and validated arguments;
- actor identity and transport;
- grant and authorization decision;
- Mission, WorkItem, and Attempt when applicable;
- caller-stable idempotency key;
- expected WorkItem version and other preconditions;
- correlation and causation IDs;
- dry-run or effect preview;
- result and structured effects;
- timestamps and status.

Transports are:

```text
liveview
mcp
cli
worker
advisor
caretaker
system
```

Actor and transport are separate. A caretaker calling over MCP is a caretaker
actor via MCP, not an anonymous MCP actor.

OperationCall states are:

```text
proposed
waiting
running
succeeded
failed
denied
stale
cancelled
```

`proposed`, `waiting`, and `running` are nonterminal. `waiting` names a Gate
or another explicit precondition. `stale` means authorization or expected
world state changed before the effect could be applied.

All state-changing actor calls and consequential external effects get durable
OperationCall rows. This includes calls initiated by LiveView, MCP, CLI,
workers, advisors, caretaker, and system reconciliation. Reads are durable
only when an audit policy explicitly requires it.

A deterministic Attempt may invoke one or more Operations. An actor may also
invoke an Operation without an Attempt, such as pausing a routine from the
CLI. The two records are linked when both exist and are never conflated.

#### Idempotency

For commands, the caller supplies a stable key in the scope declared by the
OperationDefinition. The dispatcher atomically claims that scope and key.

A repeat:

- returns the existing terminal result;
- or returns the existing nonterminal call handle;
- and never repeats the effect.

An Oban retry uses the same OperationCall. A deliberate semantic retry creates
a new OperationCall with a new key and a causation link to the prior call.

External handlers must also have an effect-level strategy, because a process
can die after the remote effect and before the local success transaction.
The golden workflow below names each strategy.

### WorkEvent

A WorkEvent is a typed append-only account of:

- WorkItem transitions;
- Attempt transitions and outcomes;
- OperationCall decisions and effects;
- external observations;
- Gates and their resolutions;
- Artifacts and evidence.

Mutable records remain the current source of truth. This is not full event
sourcing.

The existing feed becomes a compatibility projection of WorkEvents while
continuing to show legacy events. A feed entry is not sufficient as an
idempotency record or typed lifecycle log.

### Artifact

An Artifact is evidence or output with provenance:

- ContextBundle;
- diff, branch, commit, or pull request;
- test, format, static-analysis, or coverage report;
- workflow report;
- review;
- external snapshot;
- recommendation;
- notification draft;
- provider transcript reference.

Where possible, an Artifact carries a digest or stable external identity,
producer Attempt, WorkItem, Mission, media type, location, size, and retention
policy.

The storage doctrine in design/002 continues to apply. Queryable metadata and
provenance live in the database. Large bodies may remain files.

### Gate

A Gate is a durable decision blocking a specific proposed WorkItem transition
or OperationCall.

Gate v2 carries:

- Mission and WorkItem;
- optional Attempt and OperationCall;
- proposed transition or effect;
- explicit preconditions;
- requester and resolver;
- status, resolution, and reason;
- staleness rules.

A Gate authorizes exactly what its preview describes. Approval does not waive
grants, policy, WorkItem version, or external revision checks.

A merge Gate becomes stale when any pinned head SHA, checks, approvals,
review state, policy version, or WorkItem version changes. A stale Gate cannot
be approved or reused; reconciliation may propose a new one from a fresh
snapshot.

Legacy agent gates remain readable during migration. They are not silently
converted into work gates.

### ContextBundle

A ContextBundle is a versioned reproducible dossier compiled for one Attempt.
It includes:

- objective and acceptance criteria;
- Mission instructions, policy, and budget;
- RoleTemplate and recipe versions;
- relevant knowledge with provenance;
- prior Attempt outcomes and focused failure evidence;
- external snapshots and expected revisions;
- WorkspaceLease reference;
- allowed Operations and tools;
- output contract.

It is not ambient mutable agent memory.

The database stores bundle identity, provenance, digest, and Artifact
location. The body follows design/002 and may be file-backed. The exact
bundle used by an Attempt must remain reproducible after a restart.

### WorkspaceLease

A WorkspaceLease explicitly owns a working directory or worktree and, where
needed, repository landing rights.

It carries:

- owner WorkItem and Attempt;
- repository or other target;
- path or workspace identity;
- expected base revision;
- acquisition, heartbeat, expiry, and cleanup state;
- landing serialization scope.

The current repository GenServer continues to serialize GitHub mutations.
Generic workers do not run concurrently against local work until leases and
durable Attempt ownership exist. Landing remains sequential per repository.

No migration issue may assume `git_wrapper_ex` is already integrated. It is
not a current dependency.

### Automation and Observation

An Automation defines a schedule, webhook, or monitor. A run produces typed
Observations.

An Observation may:

- update an existing WorkItem;
- create a proposed WorkItem;
- satisfy a waiting condition;
- complete silently;
- trigger a small classification Attempt when deterministic policy cannot
  decide.

Current routine schedules, sensors, and advisors are compatibility inputs.
Sensors should eventually create or update work rather than necessarily wake
a named provider process.

## Authority: configuration versus data

The same field may never have two writable authorities.

### Declarative configuration is authoritative for

- RoleTemplate and Recipe definitions;
- provider profiles and static capability defaults;
- default policies and budgets;
- bootstrap Mission and Automation declarations;
- file-backed prompt and recipe assets.

### The database is authoritative for

- Mission identity, lifecycle, and runtime-created Missions;
- live RoleBindings, grants, and scoped overrides;
- WorkItems and Attempts;
- OperationCalls and WorkEvents;
- Gates, Artifacts, ContextBundle metadata, and WorkspaceLeases;
- current runtime overrides and history.

### Compatibility rule for legacy routines

`routines.toml` remains authoritative for legacy routine execution until a
named migration slice moves each field.

A deterministic adapter creates mapping records:

- a legacy-derived Mission or RoleBinding records `legacy_routine_id`;
- fields sourced from that routine are read-only on the database projection;
- new database-native records have no writable TOML twin;
- no bidirectional synchronization is introduced;
- once a field moves to the database, its old representation becomes
  read-only compatibility input or is removed.

Each RoleBinding records an authority source such as `legacy_routine` or
`database`. One record cannot be writable from both.

This resolves #300 without declaring all configuration to be data. Templates
remain declarative; live identity and history are records.

## Initial Mission mapping

The adapter stores explicit mappings once and never heuristically remaps them.

| Current routine kind | Initial target |
| --- | --- |
| Repository backlog routine | One persistent Mission per GitHub repository target. |
| Multiple routines for one repository | Separate RoleBindings in the same repository Mission. |
| `custode` caretaker | Persistent system Mission for operating Custode. |
| `quakes` | Persistent USGS watch Mission. |
| `stars` | Persistent observation Mission for star tracking. |
| `contributors` | Persistent observation Mission for contributor tracking. |
| `reviewer` | RoleTemplate used for review Attempts inside repository Missions; the global routine remains a compatibility trigger until replaced. |
| `consistency` | Ephemeral multi-target Mission per investigation; the global routine remains a compatibility trigger. |
| One-shot request with no scope | Auto-created ephemeral Mission. |

The repository vertical backfills only the chosen repository Mission and its
legacy routine mappings first. Global reviewer and consistency mappings use
explicit seed declarations and do not block it.

## Attention remains derived

Gates, asks, suggestions, exceptions, WorkItem state, and OperationCalls are
authoritative. Attention is a ranked projection of unresolved obligations.

The current one-signal-per-agent resolver remains during compatibility.
Work-aware attention later ranks obligations across Missions and WorkItems;
it does not require an `attention_items` source-of-truth table.

Durable delivery or read state may be added only for a concrete requirement,
as the current inbox read mark already demonstrates. It does not make the
ranked attention projection authoritative.

## Concurrency and stale state

Every WorkItem has a monotonically increasing integer version.

Every transition and state-changing OperationCall checks:

- expected WorkItem version;
- work-kind and workflow version;
- expected external revisions relevant to the effect;
- applicable policy version;
- active lease identity when a workspace is involved.

A mismatch returns `stale`, records the observed difference, and performs no
effect. The process manager then reconciles from a new world snapshot.

GitHub operations use the strongest available external revision:

- repository ID and issue number for issue identity;
- issue or PR updated-at identity for comment and label reconciliation;
- PR head SHA for checks, review, publication, and merge;
- webhook delivery ID for callback deduplication.

Expected external revisions supplement WorkItem version. Neither replaces the
other.

## The process manager

The process manager is deterministic. Given:

- current Mission and WorkItem;
- current WorkItem version;
- work-kind definition and policy;
- active Attempt, OperationCall, Gate, and WorkspaceLease records;
- a typed world snapshot;

it chooses one of:

```text
dispatch an Attempt
invoke or propose an Operation
wait for a named condition
open a Gate
complete
cancel
block
```

It does not contain provider conversation state. It emits ID-based Oban
commands. Job arguments carry stable IDs and expected versions, not full work
payloads.

Duplicate callbacks, process restarts, Oban retries, and reconciler overlap
must converge on the same record and effect.

## Golden workflow: GitHub issue to merge

The first work kind is `github_issue_to_merge@1`.

Its phase vocabulary and normal path are:

```text
discovered
triaging
eligible
preparing_workspace
compiling_context
implementation_ready
implementing
verification_ready
verifying
repair_ready
repairing
publication_ready
publishing
awaiting_review
feedback_ready
handling_feedback
conflict_ready
resolving_conflict
merge_ready
merging
landed
```

`ineligible` is a proposed disposition, not invisible work. A
`custode:ignore` label may project to `proposed / ineligible` with the policy
reason. Removing the label permits deterministic re-evaluation.

Blocked and cancelled items retain their last workflow phase and carry a
structured reason.

### Transition and effect table

| Step | State / phase after decision | Executor or operation | Durable evidence, idempotency, and stale rule |
| --- | --- | --- | --- |
| Reconcile issue | `proposed / discovered` | Deterministic observation | Upsert by `github:<repo-id>:issue:<number>`. Webhook delivery IDs deduplicate callbacks. A poll and webhook converge on the same WorkItem. |
| Evaluate eligibility | `proposed / triaging`, then `ready / eligible` or `proposed / ineligible` | Deterministic policy; classification Attempt only for genuine ambiguity | Store source snapshot, disposition, policy version, and reason. A changed issue revision causes re-evaluation. |
| Claim resources | `active / preparing_workspace` | Deterministic Attempt | Unique active WorkspaceLease for the repository and WorkItem, with expiry and expected base SHA. Repeating acquisition returns the same live lease. A moved base marks preparation stale. |
| Compile context | `active / compiling_context`, then `ready / implementation_ready` | Deterministic Attempt | ContextBundle Artifact keyed by input digests, work version, policy, recipe, and external revisions. Identical inputs reuse the Artifact. Any changed input produces a new digest. |
| Implement | `active / implementing`, then `ready / verification_ready` | Model Attempt through existing `ObanClaude` adapter first | Persist exact ContextBundle digest, provider metadata, outcome, usage, changed-file and diff Artifacts. Oban retries keep one Attempt ID. A semantic retry creates a new Attempt. |
| Verify | `active / verifying`, then `ready / publication_ready` or `ready / repair_ready` | Deterministic Attempt | Command spec digest plus workspace revision keys structured evidence. Verification is independent of the implementation model. Changed workspace content invalidates the evidence. |
| Repair | `active / repairing`, then `ready / verification_ready` | Mechanical handler or focused model Attempt | Classify infrastructure retry, known mechanical repair, semantic repair, human question, or block. A focused Attempt receives the failure Artifact. Policy bounds the loop. |
| Publish draft | `active / publishing`, then `waiting / awaiting_review` | Deterministic Git and `github.open_pr` Operations | Stable branch identity derived from WorkItem. Search local branch, remote branch, and PR head before create. Record PR Artifact and head SHA. Existing matching PR returns success. Divergent head is stale, never overwritten silently. |
| Await CI and review | `waiting / awaiting_review` | Webhook plus periodic reconciler | No provider and normally no queued job. Deduplicate webhook delivery. Snapshot head SHA, checks, reviews, comments, and updated-at. |
| Handle feedback | `ready / feedback_ready`, then `active / handling_feedback` | Mechanical fast path or focused model Attempt | Comment IDs and head SHA identify consumed feedback. New feedback or a changed head makes an in-flight plan stale. Return through verification before waiting again. |
| Resolve conflict | `ready / conflict_ready`, then `active / resolving_conflict` | Mechanical fast path or focused model Attempt | Workspace lease and expected base/head revisions are required. Rebase or conflict result is an Artifact. Return through verification. |
| Propose merge | `waiting / merge_ready` | Gate for `github.merge_pr` OperationCall | Pin WorkItem version, PR head SHA, required checks and conclusions, latest review state, approvals, and policy version. Any difference stales the Gate. |
| Merge | `active / merging` | Deterministic `github.merge_pr` Operation | Recheck every precondition immediately before the effect and pass expected head SHA to GitHub where supported. Already merged at the expected commit is idempotent success. Closed-unmerged or changed head is stale. |
| Complete and clean | `completed / landed` | Deterministic Attempt plus cleanup Operations | Record merge commit, final acceptance evidence, cost rollup, and completion outcome. Release lease and worktree idempotently. Cleanup failure creates an exception obligation but does not erase a successful merge. |

### Golden workflow invariants

1. An agent never writes arbitrary WorkItem state.
2. A model may propose; the work-kind module validates and applies.
3. Every external effect has a local dispatcher key and an effect-level
   idempotency strategy.
4. Verification is a separate Attempt from implementation or repair.
5. A failed Attempt never becomes a failed WorkItem state.
6. Waiting work has no live provider identity.
7. Merge approval is an exact, stale-aware OperationCall Gate.
8. The current GitHub head and current WorkItem version are checked at effect
   time, not only when a Gate was displayed.
9. Landing is serialized per repository even if investigation later fans out.
10. GitHub marker comments remain collaboration projections, not the sole
    lifecycle source of truth.

## Current concept compatibility and deletion conditions

| Current concept | Target concept | Compatibility strategy | Old path may be deleted when |
| --- | --- | --- | --- |
| `Custode.Routine` | Mission reference, RoleBinding, Automation, Recipe, execution policy | Deterministic adapter; legacy execution stays live. | Every field has moved once and no active WorkItem depends on legacy dispatch. |
| routine profile | RoleTemplate and default executor policy | Read as template input from config. | RoleTemplate config is authoritative and no runtime code reads the old profile shape. |
| role tier and MCP allowlist | Capability set and operation grants | Preserve current grants behind authorization adapters. | Every affected command is registry-dispatched and tests prove equal or tighter authorization. |
| named `ObanClaude` agent | Executor runtime for an Attempt | Existing Claude path is the first adapter. | No WorkItem lifecycle depends on agent process identity. |
| Claude session ID | Opaque Attempt continuation | Store as provider metadata. | Never a deletion target; it remains optional diagnostic metadata. |
| `RoutineTick` | Legacy Automation occurrence | It may create or wake work through the adapter. | Migrated Automations dispatch ID-based commands without it. |
| Oban job | Physical dispatch and retry | Carry Mission, WorkItem, Attempt, or OperationCall IDs. | Full work payloads and provider ownership are absent from job args. |
| notebook todo | Legacy task, plan item, or note | Classify only when touched; retain provenance. | No automatic bulk deletion or migration. |
| journal entry | Mission knowledge, WorkEvent summary, or Attempt finding | Retain legacy access and gradually rescope new writes. | Retention policy can distinguish migrated records. |
| memory row | Scoped context source | Include with provenance in ContextBundle. | Private agent ownership is no longer required by migrated recipes. |
| agent inbox file | Executor message input | Keep separate from operator Attention. | It may remain permanently as a provider-native delivery channel. |
| `Workflow.Run` | Workflow execution or Attempt group | Add parent WorkItem reference and reuse resumability. | Never rename wholesale; delete only if a later unified execution store proves equivalent. |
| workflow node result | Attempt result or Artifact | Link existing row and avoid copying large payloads. | All consumers read through Artifact or compatibility projections. |
| workflow launch proposal | Proposed workflow Attempt or control WorkItem | Project feed proposal into typed Operation, Gate, and work records. | No launch decision depends only on a feed scan. |
| gate | Gate over a transition or OperationCall | Gate v2 beside legacy agent gates. | No active legacy agent gate remains and callers use work scope. |
| ask | Attention source | Add Mission, WorkItem, and Attempt scope when applicable. | Legacy agent-only asks have aged out under retention. |
| attention signal | Derived obligation projection | Generalize from agent facts to work and control facts. | Never replace with a source-of-truth table without a delivery requirement. |
| feed entry | Compatibility activity projection | Project WorkEvents and keep legacy events. | No current screen or metric depends on untyped lifecycle parsing. |
| spend row | Attempt usage attributed through WorkItem and Mission | Add work dimensions while retaining provider and legacy routine. | Legacy agent dimension is no longer required for historical diagnostics. |
| `Custode.Repository` | Source-control adapter and mutation chokepoint | Keep and dispatch its verbs through Operations. Service follows Missions or leases. | Routine-derived service and direct transport calls are gone. |
| issue marker comments | External projection | Reconcile markers to phase during migration. | WorkItem state is authoritative for every migrated issue. |
| sensor | Automation and Observation adapter | Create or update work before spending a model turn. | No sensor has to wake a named routine to express an observation. |
| advisor suggestion | Typed policy proposal or control WorkItem | Defer until repository vertical is stable. | Suggestions use shared Operations and outcomes. |
| sub-agent row | Child Attempt, or child WorkItem with an independent outcome | Link new delegations to work; keep orphan reconciliation. | Process identity is no longer the domain parent. |
| issue draft | Artifact awaiting an Operation or Gate | Link to creator Attempt and WorkItem. | Batch filing reads only Artifact and Operation records. |
| disowned PR | External exception and disposition | Link to WorkItem or create exception attention. | No attention rule depends on an agent-only record. |
| agent panel | Legacy runtime projection | Do not extend during the kernel migration. | Mission/work views or generated operation forms satisfy the proven need. |
| Fleet LiveView | Runtime and operations projection | Keep throughout migration. | No deletion is planned. |
| Repos LiveView | Repository Mission projection | Add work read models beneath it after the vertical works. | Direct routine grouping is no longer needed. |
| Inbox LiveView | Global Attention projection | Retarget to work and control obligations. | Agent-only resolver is no longer its complete input. |
| caretaker | Optional operator client | Use the same operations and grants as every other actor. | Side doors are gone; the caretaker itself remains optional. |

## Migration invariants

1. Keep Custode a modular monolith.
2. Keep current routines running until their replacement path is proven.
3. Add records alongside existing tables; no flag-day rename.
4. Introduce compatibility projections before changing the primary UI.
5. Keep Oban arguments ID-based.
6. Preserve current MCP and CLI contracts where practical.
7. Preserve typed repository operations, per-repository serialization, and
   policy checks.
8. Preserve feed history and derived Attention during transition.
9. Do not add a generic worker pool before WorkspaceLeases and durable
   Attempt ownership.
10. Do not add a second provider before the Executor contract is exercised by
    the existing Claude path.
11. Do not automatically migrate every todo, journal entry, or memory into
    work.
12. Do not make Mission a new god object.
13. Do not use GitHub comments as the only lifecycle state after cutover.
14. Do not conflate phase, board lane, queue, and executor capacity.
15. Do not introduce bidirectional TOML and database synchronization.
16. Do not broaden authorization while routing current guards through the
    operation dispatcher.
17. Do not redesign Mission or board UI before the repository vertical
    produces authoritative records.
18. Do not assume `git_wrapper_ex` exists in Custode.
19. Repair checked-in migration reproducibility before adding kernel
    migrations. The local `agent_panels.kind` column came from
    `20260722000004_add_panel_kind.exs` on parked commit `5a41a5f`; the local
    `schema_migrations` records that version, but `main` does not contain the
    migration or use the column.
20. Exercise the current workflow durability path before treating its rows as
    production-proven Attempt storage.

## Dependency order

The implementation backlog follows this order:

Issue #354 is the live dependency checklist. Issue wording may be groomed as
evidence arrives, but it may not invert these architectural layers without a
new decision record.

1. **Operation spine:** definitions, registry, envelope, dispatcher, durable
   write-call audit, idempotency, then one existing write through LiveView,
   MCP, and CLI.
2. **Mission scope:** Mission lifecycle, deterministic legacy mappings, then
   RoleTemplate and RoleBinding compatibility.
3. **Work kernel:** WorkItem transitions, Attempt and Artifact provenance,
   work-scoped Gate v2, then the process manager and ID-based Oban commands.
4. **Golden repository vertical:** intake, lease, context and Claude,
   deterministic verification, repair, publication, review reconciliation,
   and stale-aware merge completion.
5. **Projections:** Mission/work reads, generalized Attention, cost/outcome
   attribution, then MCP resources.
6. **Executor expansion:** provider-neutral contract through Claude, safe
   capability pool, then a second provider.
7. **Product expansion:** Mission UI, one non-repository proof, control work,
   prompts/tasks decisions, and cross-repository scheduling.

Later layers do not become `workable` merely because they have issue text.
Their dependencies must be shipped and exercised first.

## First implementation and first vertical milestone

The first implementation issue is the operation definition registry, envelope,
and dispatcher. It should use `fleet.pause_agent` as the first bounded
operation because pause already exists in LiveView, MCP, CLI, and the
`Custode` facade; it is reversible and has no GitHub effect.

The first work-first vertical milestone is:

> One configured repository routine observes one GitHub issue, idempotently
> creates a WorkItem in the repository Mission, launches one Claude Attempt
> through existing `ObanClaude`, persists its ContextBundle
> digest/outcome/usage/Artifacts, and leaves current UI and routine behavior
> intact.

Definition of done:

- restart-safe;
- duplicate intake and Oban retry safe;
- current routine remains the compatibility driver;
- no generic worker pool;
- no second provider;
- no Mission board redesign;
- one typed transition and event timeline;
- cost attributed to Mission, WorkItem, Attempt, provider, and legacy routine;
- a clear next transition exists even when publication and merge remain
  legacy.

After observing that slice in real use, extend the same WorkItem through
verification, publication, review, and merge. Do not start a parallel
architecture track.

## Deliberately deferred

- exact Mission and board UI;
- final lane vocabulary;
- global cross-repository fairness;
- final provider capability negotiation;
- Codex continuation details;
- MCP prompts and MCP task projection;
- advisor autonomy ladders;
- whether all configuration eventually leaves TOML;
- sophisticated Mission relationships and multi-target schema;
- complete non-repository workflow catalog;
- crew-yield scoring;
- complete event sourcing;
- distributed execution.

## Remaining operator choices

These are policy or rollout choices, not missing kernel contracts:

1. Confirm the explicit seed mapping for global `reviewer` and `consistency`
   compatibility routines before their backfill.
2. Confirm whether `stars` and `contributors` remain separate observation
   Missions or share a broader ecosystem Mission.
3. Choose initial `auto`, `ask`, and `ineligible` policy assignments by
   Mission, operation risk, and repository. The meanings are settled:
   `auto` still records and authorizes a typed Operation, `ask` opens a Gate,
   and `ineligible` creates an explicit proposed disposition.
4. Choose the pilot repository and issue for the first work-first vertical.
   `genagent/custode` through `custode-dev` is the grounded default.
5. Approve the repair disposition for the parked panel-v2 migration recorded
   in the live local database before the first kernel migration.
6. Choose a bounded workflow, repository, and spend rail for exercising
   restart durability before workflow rows are linked to Attempts.

Choices 1 through 4 do not block the first operation-spine issue. Choice 5
gates the first kernel migration. Choice 6 gates linking current workflow rows
to Attempts.
