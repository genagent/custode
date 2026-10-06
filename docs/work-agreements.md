# Work agreements on the routine path

A work agreement records what a configured routine owns: an outcome, completion
criteria, boundaries, an assignment identity and references. It is optional for
ordinary conversation and can describe standing maintenance as well as a bounded
research or implementation task. GitHub remains authoritative for issues and PRs;
link them instead of copying a second backlog.

Creating, revising, reading, checkpointing, submitting or resolving an agreement
never starts an agent, queues a message or changes a gate. Use existing authorized
messaging to request execution separately. Restarting a reader cannot redispatch
work. Agreements add no scheduler, per-agreement process or kernel dependency.

## Recorded intent and evidence

The immutable intent revision contains `outcome`, uniquely named `criteria`,
`assignment_id`, `boundaries`, `request_references`, `inputs` and
`expected_outputs`. The owning routine is fixed at creation. Helper epochs and
operator or peer request IDs can be linked as references; a reference never
transfers ownership or grants access to the referenced source.

A checkpoint records its author's summary, next steps, blockers and decisions.
Each blocker or decision names a resolver. These are attributed assessments,
separate from the independently observed execution facts in project progress.

A submission names its intent revision and assignment identity, outputs,
evidence against named criteria and verification limits. A negative research
finding may have no output artifact. Evidence can be incomplete; a submitted
result is never automatically verified or accepted. References are opaque,
attributed links. Custode neither dereferences nor verifies their contents.

A human resolution names an exact submission, a decision (`accepted`,
`changes_requested` or `rejected`) and a reason. Each submission has at most one
resolution. Further work produces a new submission, which can receive its own
resolution. Agreement acceptance grants no gate approval, designated-human
Assurance judgment, shell permission, replacement authority or retry permission.
Link a separate Assurance record when that protocol is appropriate.

## Revision and retry behavior

Intent revisions and record sequences are separate counters. Revising intent
increments its revision; every checkpoint, submission and resolution appends a
record and increments the sequence. Existing records are retained.

Revisions and checkpoints require `expected_revision`. Resolution also requires
that the named submission belongs to that current revision. A late submission
may name an older, existing revision and remains visible in history, but cannot
be accepted as the current outcome. Changing criteria cannot carry earlier
acceptance forward. The current resolution always belongs to the current
revision's latest submission; an earlier accepted submission does not make a
newer, unreviewed submission accepted.

Every mutation requires a caller-chosen `request_id`. Within one authenticated
actor, an exact retry returns the original receipt with `duplicate: true`, even
when intent has subsequently changed. Reusing that ID for a different operation,
target or payload returns an idempotency conflict. Authority is checked again on
retry. Atomic database transactions protect revision checks and record appends.

## Clients and authority

All clients use the same service and projection. The MCP tools are
`work_agreement_create`, `work_agreement_revise`, `work_agreement_checkpoint`,
`work_agreement_submit`, `work_agreement_resolve` and `work_agreement_read`.
The read tool accepts an agreement ID for its current record and bounded history,
or a routine ID to discover that owner's agreements. See the generated
[MCP reference](mcp-reference.md) for exact argument limits and result shapes.

The human operator and a caretaker with captured execution authority may create
or revise agreements. An owner routine can checkpoint and submit its own work;
the operator can also record a result with the operator's own attribution.
Only the human operator resolves a submission. Operator and caretaker readers
can inspect all owners; a routine can inspect only its own agreements. Temporary
agent credentials are not admitted. Identity comes from the authenticated
surface, never a payload field.

`ProjectProgress.work_agreements` contains the same bounded current projection
as the read tool. Each record retains its source, timestamp and author. These
fields support a dashboard without a fresh model call:

| Dashboard field | Source |
| --- | --- |
| Purpose | Current intent outcome, criteria and boundaries |
| Done | Exact current submission and human resolution; acceptance is not independent verification |
| Doing | Existing observed execution and current-run facts, outside the agreement |
| Todo | Current revision's latest checkpoint next steps |
| Decisions | Attributed checkpoint decisions and their resolvers |
| Blockers | Attributed checkpoint blockers and their resolvers |

List pagination follows stable creation order; record history follows immutable
sequence order. Re-read the current projection before acting: observation times
are not an atomic snapshot of agreement, execution and attention together.
