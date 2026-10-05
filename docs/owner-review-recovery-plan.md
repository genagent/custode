# Owner review cancellation recovery, #778

Retain a per-child cancellation request before delivering it to Oban, bound to the existing review, child slot, durable attempt, job id and frozen launch arguments. Keep a bounded delivery receipt that distinguishes an observed cancellation request, delivery refusal/failure, missing job, and native settlement unknown. Existing accepted results and once-only usage remain immutable.

Explicit cancel and reconcile operations recover pending delivery after a coordinator crash. They never launch or retry a provider call. Exact owner authorization and current routine revision are rechecked using the existing serialized admission path. Delivery must match the owned job and immutable child binding; mismatched jobs are refused rather than cancelled. Completed observations do not free reservation or imply subprocess death. Reads remain inert, and old rows missing this cancellation receipt are shown as legacy until an explicit cancellation operation binds the current request.

Persist durable bounded job-state observations during explicit reconciliation, including job attempt/state or missing job, without treating terminal Oban state as native settlement. No new table or scheduler is needed; optional fields live in the existing owner_reviews record.

Files: lib/custode/owner_reviews.ex and a shared bounded cancellation helper if needed; owner review tests; design/017-owner-ensembles.md and MCP behavior/reference documentation. The existing owner_review MCP entry and operator/owner scope are retained.

Validation: all five gates before every push; focused seeds 1, 12345 and 777. Synthetic tests cover a crash between durable request and delivery, request observed before receipt persistence, duplicate cancel/reconcile, missing or changed job, current owner refusal, terminal and late completion preservation, restart-like record reload, and no provider invocation during recovery. No paid calls.

Out of scope: Codex admission, hard token caps, native process or all-descendant settlement claims, release of unknown-spend reservations, automatic fanout/retry, new runtime migration, acceptance/approval or effect authority. #778 remains open for the unsupported provider/cap/settlement guarantees.

Operating note: no migration or prompt changes. Pull and restart loads the new optional cancellation/job observations; older records cannot gain historical native evidence retroactively.
