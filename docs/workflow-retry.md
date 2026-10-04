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

Pull/restart installs this read projection. No migration, prompt change, new retry
authority or release-policy change is included.
