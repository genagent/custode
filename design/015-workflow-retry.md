# 015: Workflow failure identity and retry

Status: prerequisite implementation and bounded retry contract, #750.

A failed stage is readable today. Retrying it is a different execution with
possible side effects and cannot be implemented by changing failed to running.

## Evidence retained now

New launches store an execution generation and a data-only definition snapshot:
ordered stages, node templates, schemas and configured model/effort. Its hash
identifies those configured inputs, not a resolved provider alias, CLI version,
effective host policy or proof that a node is read-only.

A terminal node failure retains stage, node, arguments hash, execution generation
and callback job id when present. Callback admission and result acceptance use an
immediate SQLite transaction. New callbacks must match the run, stage, generation
and a recorded node job; production callbacks also supply that job's exact id.
The first accepted result wins. Failed/complete runs, old stages, stale generations
and contradictory later failures cannot rewrite their accepted state.

The checklist reads saved stage order even if the catalog changes or disappears.
Advancement refuses a changed definition instead of silently executing its new
meaning. Legacy rows retain their existing fallback and never acquire invented
launch snapshots or retry eligibility. Executing legacy work can finish under its
recorded cursor; terminal callbacks are still refused.

## Retry admission contract, not yet enabled

Use an operator-only shared action. Require the displayed failed generation and
a request id. In one immediate transaction, validate the failed run and its
snapshot, record a new execution generation and enqueue its exact pending nodes.
An identical request returns the recorded retry; a different request against an
old generation is stale. An enqueue failure rolls back the admission. MCP, CLI
and LiveView must call that action with the same policy, not separate handlers.

Before admitting:

1. Establish that every old sibling is settled. A cancellation request, expired
   lease or killed BEAM waiter does not establish provider subprocess settlement.
2. Reuse only accepted successful results whose execution and rendered input
   hashes are validated against the captured definition. Keep original attempts
   inspectable; never upsert a new result over a prior accepted attempt.
3. Carry cumulative prior spend into the retry's rail. Repeated retries do not
   create fresh uncharged budgets. Insufficient headroom returns a budget reason.
4. Establish an enforceable replay policy for the failed and remaining nodes.
   Unknown/side-effecting executions are non-retryable unless their specific
   effects have an idempotent replay or reconciliation contract. Restricting
   Write/Edit/NotebookEdit leaves shell and MCP writes possible. Prompt promises
   and model-reported verification do not establish replay safety.
5. Revalidate current launch authority, host availability and exact execution
   limits before a provider starts. A workflow definition hash is insufficient
   evidence of those settings.

A future retry generation's callbacks can only modify that generation. Late old
callbacks remain evidence, never replacement results. Preserve budget-pause
resume as a separate action.

## Next implementation

Keep #750 open. Add atomic retry records/admission and an enforceable replay-safe
execution profile together, including settled-sibling proof and cumulative rails.
Exercise simultaneous clicks, enqueue rollback, old callback races, retained prior
stages, changed/missing definitions, unsafe shell/MCP capabilities and depleted
budget. Offer Retry at the failed stage only when its eligibility is established;
otherwise show its concrete reason. No retry button or MCP retry verb ships in
this prerequisite.

## Operating note

Adds nullable workflow identity columns. Pull, migrate and restart. Already
queued jobs retain legacy metadata and behavior; snapshots are captured only for
new launches. This does not change approval classes or permit new work.

## Frozen result contract prerequisite (#750)

New launches mark their host result-contract version in the run and retain the
exact stored job-argument, pinned-policy/package, captured-definition and input
bindings. Before execution, new jobs must still match their stored record,
current run generation/stage and single allowed attempt. A missing or changed
contract cannot downgrade a new run to legacy behavior. This is a host admission
observation; it does not prove effective native configuration or tool confinement.

Completion admission checks the same bindings in its existing immediate SQLite
transaction. The frozen node schema, declared model/effort and rendered input
hash must match the job. Supported structured results retain a nullable validation
receipt and their original job/generation/input/schema digests. The first accepted
result still wins. Invalid or unsupported new structured output fails the current
stage, preserving earlier accepted siblings; stale callbacks remain inert.
Already queued legacy jobs keep their previous text fallback and remain unbound.

The versioned validator accepts type, required, recursive properties/items and
additionalProperties, enum/const, numeric bounds, uniqueItems, and array/object
size bounds. Schema annotations have no assertion meaning. Explicit `$schema`
dialect declarations are refused at every nesting level. Other assertions,
including references/combinators, format, pattern, multipleOf and string length
bounds, are unavailable rather than ignored. This avoids claiming full JSON
Schema conformance from the current basic validator.

RetryStatus exposes at most 100 retained result-validation summaries and an
explicit truncation flag. Schema validation is not a native attempt receipt,
all-descendant settlement, effect-replay contract or authorization to reuse a
result. Its retry_offered flag stays false and no retry verb ships here. A direct
host callback without an attempt observation remains attempt_binding=unavailable.

Operating note: pull, migrate and restart for the nullable result validation
column and new-launch contract. No existing result acquires historical evidence
retroactively. Existing launch approval and budget-rail resume remain separate.

## Explicit new-job execution profile

Design/030 adds an opt-in `custode.workflow_tool_free.v1` definition profile.
Its frozen host policy pins empty built-in tools/MCP, sealed settings and hooks,
a fresh single native turn, admitted USD stop and whole-command deadline.
Default workflows and historical definition fingerprints stay unchanged.
The retained result contract includes exact effective query options/package
versions for selected jobs and refuses altered or missing policy bindings.
This is a requested host profile, not native conformance, all-descendant
settlement, a hard token cap or a retry grant. RetryStatus still refuses retry.
