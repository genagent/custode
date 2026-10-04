# 026: Missions without another work engine

Status: bounded design review for #459, 2026-10-04. Runtime implementation and
comparative delivery proof remain deferred. Inspected baseline: `4ebb581`.

## Decision

Keep the project-manager/routine path as the first mission candidate. A
mission is a bounded objective owned by a coordinator, with completion
criteria, assignments and linked evidence. That vocabulary is useful; a new
scheduler, work board or Mission-backed execution path has not earned its
cost. Begin with the manager notebook, GitHub issues and existing peer mail.
No runtime change follows from this note.

The minimum case that can justify more machinery is one real objective with
two workers whose dependencies or handoffs cannot be handled as cheaply by
one routine working a labelled backlog. Two agents merely doing independent
issues do not establish that case. The current manager and mixed-provider
routines make a comparison possible, but their existence is not proof that
missions improve delivery.

## What exists on this baseline

| Piece | Useful role | Limit |
|---|---|---|
| Manager entry point and prompt | `/custode` uses `ConversationLive`; `priv/prompts/caretaker.md` already requires plans, current project evidence, bounded delegation and verified results | A notebook plan is agent-authored, not a mechanical mission lifecycle |
| `project_progress` | Reads current operator exchanges, execution, blockers and recent reports without dispatching | Reads are separate observations; a successful turn or report does not verify acceptance |
| `PeerMessages` and `PeerMessage` | Authenticated sender, durable request/FYI/reply, stable ID, correlation root, retry key, acknowledgment and bounded wake-up | Delivery state is pending/delivered/failed; it has no accepted-assignment or completed-work state |
| `Notebook` | Durable journal, memory and todos; workspace files are regenerable views | Free prose needs explicit IDs and reconciliation to recover assignments |
| Routine delegation and one-shot jobs | Existing execution, budgets, parent ownership and result paths | Configured peers and owned children have different authority; peer mail adds no control edge |
| `Workflow`, `Workflow.Run`, `Workflow.Runner` | Predeclared barriers, structured node results, run budget, durable stage cursor and restart recovery | Node execution is Claude-based; a dynamic mixed-provider writing crew is not the existing workflow contract |
| `Mission`, `Missions`, legacy projection and work resources | Existing kernel scope records and compatibility read projections | Active/archived scope does not supply a bounded objective's acceptance lifecycle; compatibility records can still exist while intake is frozen |

The workflow worker disables named Write/Edit/NotebookEdit tools but does not
mechanically confine Bash, native settings or MCP writes. It also retains an
explicit limitation: stage retry remains unavailable until worker settlement
boundaries are proved.
Reusing workflow persistence is not grounds to claim mission cancellation,
retry or safe worker replacement.

## Minimum useful protocol

This is a proposed convention over existing records, not a new schema or MCP
contract. Keep one durable objective record in the coordinator's notebook,
referencing a parent GitHub issue for repository work. Keep issue ownership
and PR state on GitHub rather than copying an authoritative backlog.

1. **Define.** Record objective ID, owner, repositories, requested outcome,
   acceptance evidence, exclusions, authorized scope, budget/concurrency
   limits and stop conditions. A proposal is distinct from authorized work.
2. **Assign.** For each bounded assignment, record owner, dependencies,
   issue/artifact links and expected reply. Send through existing peer mail
   to configured owners or the existing delegated-child path when ownership
   permits. Retain the exact request ID and correlation root. Retry an
   unchanged request with its stable key; changed scope creates a new request
   naming what it supersedes. A notebook entry alone dispatches nothing.
3. **Track.** Distinguish requested, acknowledged, reported, blocked and
   accepted in the plan. These are coordinator assessments, not new provider
   or transport states. Record the last evidence read and next action.
   Acknowledgment proves receipt; only evidence of the requested outcome
   permits acceptance. A blocker records who owes the next decision.
4. **Reconcile.** Refresh `project_progress` before a new assignment or
   reprioritization, including direct operator constraints, and inspect the
   relevant peer exchange. A fresh read is not a lock against later input.
   Honor existing rails, pauses, grants and gates. A peer request cannot grant
   tools or authorize a sibling's gated write. #554 and #555 remain separate
   operator decisions.
5. **Recover.** After a coordinator or provider restart, reconstruct the
   objective from notebook, issues, request IDs and correlated replies;
   reconcile outstanding assignments before sending more. Unknown execution
   settlement stays unknown. Do not duplicate work merely because a worker
   is offline or an answer is missing.
6. **Finish or stop.** The coordinator checks assignment evidence and the
   whole objective's acceptance criteria, records accepted and unresolved
   work, and reports the outcome to the operator. A blocked objective remains
   open. Requesting cancellation or changing a plan is not proof an existing
   execution stopped; use shared operations and their observed outcomes.

Keep summaries short and linked to evidence. The coordinator can organize
workers only through its existing authorized roster/delegation operations;
creating a mission does not grant broader approval authority. Temporary
children, configured project owners, their worktrees and their budgets keep
their current owners. No automatic crew provisioning is implied.

## Which substrate, and when

Use routines and peer mail for work whose decomposition or constraints change
during conversation. Use the existing workflow runner as an optional
subtask only when the job already fits a predeclared structured read/research
DAG and its normal launch approval and rails. A workflow result becomes
linked evidence; it does not own the objective or replace project owners.

Do not use the frozen Mission/WorkItem/Attempt path for this first proof.
`GitHubIssueIntake.on_routine_tick/1` remains `:noop` without a pilot. The
kernel's compatibility projection and read resources do not authorize intake
or execution. This decision neither deletes those records nor resumes
unscheduled kernel surfaces. Design/010 continues to govern the freeze.

## Evidence required before implementation

Choose a real bounded objective with two workers and a meaningful dependency.
Record the one-routine labelled-backlog plan first, with the same scope,
acceptance, budget and authority. Compare against the convention above on
comparable work, stating task differences rather than treating a faster
unmatched run as a controlled result.

Record accepted delivery, elapsed time, operator interventions, coordination
turns/spend, duplicate work and recovery after a coordinator restart. Include
one direct operator constraint change and one blocked or failed assignment.
The objective must complete without lost constraints, duplicate side effects
or authority bypass. Define the desired improvement with the operator before
running the comparison. Extra parallelism alone is not a benefit measurement.

Retain the simple path if it delivers with less coordination. Propose a
small implementation only for an observed failure of the convention, naming
that failure, its owner and the smallest durable operation it needs. No
comparison or live mission was executed for this review. #459 remains open
for that proof and any justified implementation; #421's multi-worker trigger
is a condition to demonstrate, not evidence supplied by mockups.

## Relationship to existing direction

Design/009's delivery benchmark and GitHub-as-future-store direction remain.
Design/010's routine product, thin shared operations and frozen kernel remain.
The completed #451 and #461 provide coordination primitives rather than a
reason to introduce another engine. Design/011 keeps project identity and
durable memory independent of provider-session handles.
