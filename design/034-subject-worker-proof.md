# 034: Canonical scoped launch arguments and worker proof

Status: implemented bounded repair and controlled worker proof, closes #832, refs #784.

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
Retain real integration snapshots. The test-only harness advances each exact
queue row into its executing first attempt and calls the real worker perform
function; the real terminal callbacks revoke the credential before the harness
marks that row complete. No model or provider CLI is called.

The first worker reads current preferences and exclusively publishes sourced,
dated research with explicit uncertainty. Its terminal run revokes the scoped
credential and removes its config. Helper/workspace cleanup preserves root,
output and immutable producer/retrieval receipts. After an external preferences
edit, a distinct fresh helper reads the new revision and retained research, then
creates a separate follow-up. Ordinary tokens gain no rights. Routine parents
may deliver work but cannot admit grants; admission remains human-only.

Files: SubjectAssignmentLaunch, focused integrated/invalid-argument regressions,
this proof record, design/021 acceptance accounting and shared MCP behavior/
generated reference notes. Native-observation callback tests also assert inside
the existing eventually helper so asynchronous capture is awaited; its retry
contract catches assertion failures, not false predicate returns. The initial
plan-head CI exposed this existing synchronization race at seed 564702. A second
CI seed, 670873, exposed the status-vocabulary fixture's unisolated whole-fleet
default selection and registry-before-durable-gate window. Its setup now clears
attention, waits for its exact durable gate and asserts its own selected subject
before comparing vocabulary; production selection and labels are unchanged.
No new authority, provider option, scheduler, store, migration, native conformance,
model receipt/use, OS confinement or physical-settlement claim. The completed
scoped-MCP acceptance accounting is recorded in design/021; #784 disposition
requires review of that evidence after this repair is validated.

Validation: the five baseline gates passed before plan publication. Integrated
main 66cf0c4, including #829 and #830; independent code/fixture/acceptance review
passed. All five gates and generated-reference check passed after the callback
repair; the full suite passed 2485 checks (30 doctests, 2455 tests), three excluded,
under the failing CI seed 670873, with zero Dialyzer errors. The earlier callback
repair also passed full seed 564702. The combined 80-test subject/context/runner/
status-vocabulary regression group passes required seeds 1, 12345 and 777. Exact updated-head CI
remains a merge requirement. Validation uses the inactive sibling's own database,
port and external temporary directory.

Operating note: newly admitted helper launches freeze the JSON-stored argument
representation. Pull and restart adopts the repair; no migration or new grant.
Existing bound launches are not rehashed, backfilled or granted a guard bypass.
The running fleet is not updated or restarted by this work.
