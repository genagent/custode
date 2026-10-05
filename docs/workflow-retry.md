# Failed workflow retry readiness

Generation and callback fencing preserve accepted results. They do not make a
failed stage safe to execute again. Current NodeJob pins off Write, Edit and
NotebookEdit, while Bash, MCP and native configuration may still permit effects.
A named-tool deny list is not filesystem or external-effect confinement.

Use `mix custode workflow-retry-status <run-id> --json`, the operator MCP
`workflow_retry_status` tool, or Why retry is unavailable on a failed workflow
card. The shared read operation reports compatible captured definition and exact
failed job/generation binding where known, bounded current queue states, truncated
inventory and explicit missing worker effect and settlement guarantees. It does
not enqueue, cancel or resume anything. Budget-paused resume remains separate.
A terminal Oban row cannot establish native descendant settlement or safe billing
replay. Reads are observations, not an atomic admission decision.

Remaining #750 implementation: enforce a worker contract with explicit bounded
effects, recorded launch/physical settlement and exact callback identity; freeze
current actor/definition/options, prior successful results and cumulative retry
rails in one idempotent admission. Reuse successful prior stages, fence late
callbacks and retain actual spend from all generations. Legacy jobs lacking proof
stay unavailable. A narrower tool-free worker can be a first supported contract;
do not silently restrict existing analysis workflows or infer no effects from a
prompt. Prove these properties before offering a retry button.

The earlier read-only projection required pull/restart without a migration.
The result-contract follow-up below adds a nullable column. Neither slice grants
retry authority or changes release policy.

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
size bounds. Schema annotations have no assertion meaning. Other assertions,
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
