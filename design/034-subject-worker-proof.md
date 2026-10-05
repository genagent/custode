# 034: Canonical scoped launch arguments and worker proof

Status: planned bounded repair and acceptance fixture, closes #832, refs #784.

Real helper launch arguments include IntegrationCatalog snapshots with nested
atom keys. Hashing the pre-storage map freezes a different identity from the
persisted JSON map, whose keys are strings; scoped HTTP access then refuses the
unchanged executing job. Canonicalize supported JSON arguments at the host scoped
enqueue boundary before Job.new, insert and binding. Unsupported nonJSON values
must refuse. Keep exact frozen argument/metadata matching and stale-turn refusal.

Exercise two fresh helpers through real start_agent, durable delivery,
SubjectAssignmentLaunch and ObanClaude.Agent.Job.perform. A deterministic test-only
ClaudeWrapper runner reads the actual issued private MCP configuration and calls
the authenticated subject_context HTTP surface while each durable job executes.
Retain real integration snapshots. No model or provider CLI is called.

The first worker reads current preferences and exclusively publishes sourced,
dated research with explicit uncertainty. Its terminal run revokes the scoped
credential and removes its config. Helper/workspace cleanup preserves root,
output and immutable producer/retrieval receipts. After an external preferences
edit, a distinct fresh helper reads the new revision and retained research, then
creates a separate follow-up. Ordinary tokens gain no rights. Routine parents
may deliver work but cannot admit grants; admission remains human-only.

Files: SubjectAssignmentLaunch, focused integrated/invalid-argument regressions,
this proof record and shared MCP behavior/generated reference notes as needed.
No new authority, provider option, scheduler, store, migration, native conformance,
model receipt/use, OS confinement or physical-settlement claim. #784 remains open.

Validation: five baseline gates before plan publication; all five gates before
every implementation push; focused seeds 1, 12345 and 777; independent review;
current-main integration and exact updated-head CI. Use the inactive sibling
worktree's own database, port and external temporary directory.

Operating note: newly admitted helper launches freeze the JSON-stored argument
representation. Pull and restart adopts the repair; no migration or new grant.
Existing bound launches are not rehashed, backfilled or granted a guard bypass.
The running fleet is not updated or restarted by this work.
