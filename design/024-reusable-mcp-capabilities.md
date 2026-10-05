# 024: Reusable reads before dynamic agent-authored tools

Status: decision and implementation accounting for #577, 2026-10-04. The two
bounded slices shipped in #800 and #807, with production shared operations from
#798 and native comparison tracking in #799. Activation remains explicit and
owner-scoped. Native long-lived refresh and individual dynamic publication remain
unproven; no generated code or mining is enabled.

## Decision

Start with a fixed compiled MCP dispatcher for a small versioned read composition,
not one generated BEAM module per discovered pattern. Definitions are validated
JSON-like data: id, description, argument/result schema, required compiled reads,
structural argument references, dependency revisions and evaluation cases. No
EEx, string interpolation, shell, eval or arbitrary module/function names. Runtime
code remains reviewed source. Missing deterministic functionality gets a separate
bounded implementation proposal, not a privileged in-process model extension.

SQLite holds immutable definition revisions, active/disabled pointers and bounded
operation traces. Authored source can stay in Git; importing source does not
activate it. Replace and rollback compare expected active revisions. In-flight
calls retain their captured revision and recheck current caller grants and active
dependencies before every dispatch. Disable stops future dispatch, but cannot
retract bytes a read already returned. Preserve partial results and the stopping
reason. Every underlying operation retains the same verified caller, never the
capability author's identity.

The first activation is human configured for one owner. Future automatic activation
can use explicit operator-configured policy over exact compiled read dependencies
and evaluation cases. A model creating a definition does not create that policy,
change ToolPolicy classification or widen a grant. Write compositions and automatic
pattern mining remain later work.

## What the pinned implementations actually support

Custode's `MCP.Snodo.plug_options/0` builds immutable routers and runtimes when the
Plug starts. Registered tools are compiled modules; Snodo Router registrations
return updated router values. Per-caller discovery and invocation authorization
exist in the pinned Snodo Router/Runtime. This does not supply Custode with a live
catalog publication service or prove Claude/Codex refresh existing sessions.
A fixed dispatcher avoids relying on mid-session catalog refresh for the first
slice. Individual dynamic tools/prompts/resources wait for actual client proofs.

`Repository.view_pr` reports current PR fields; `pr_checks` captures a head sha;
`pr_diff` currently returns PR files without a pinned head. Composing those three
calls does not create an atomic snapshot. Even matching before/after head reads
cannot rule out an intervening change and reversal. Return explicit mixed/stale
or unavailable revision binding; a truthful pinned diff needs its own repository
read improvement. Existing served-repo read policy is broader than ownership;
composition must preserve it and the current MCP eligibility without pretending
ToolPolicy metadata itself enforces caller scope.

#782 now captures exact integration tool names and access revisions. Reuse that
publication discipline; do not revive mutable external-server prefix grants.
Dynamic internal definitions do not inherit integration installation authority.

## Proof and measurements

`spikes/capabilities` is a standalone SQLite interpreter fixture. It verifies
non-executable structural substitution, explicit operator publication, current
per-operation caller checks, discovery/invocation denial, partial failures, restart,
activation compare-and-set, replacement, disable, rollback and dependency changes.
Trace records retain definition revision, caller, operation, input digest and
outcome; raw arguments/secrets are not copied into a reusable definition.

The measured consolidation is three client requests to one composition while
retaining three backend reads. This is a fixture count, not a native model token,
latency, cost or correctness improvement. That standalone interpreter remains a fixture. Production activation now exists
through the fixed dispatcher; the subsequent [native and nonpaid compatibility
proof](../docs/native-read-composition-proof.md) identifies its narrower actual
observations and unknown native refresh behavior. Do not attribute those later
observations to this interpreter.

## Shipped slices and remaining acceptance

| Acceptance | Evidence | Scope still open |
| --- | --- | --- |
| Versioned read definition and one-owner activation | #800, `ReadCompositions`, [operator contract](../docs/read-compositions.md) | No automatic publication or authored executable code |
| Caller-scoped invocation, denial and partial failures | Production shared operations and MCP tests | Does not widen current repository or role grants |
| Replacement, disable, rollback and persistence | Real operations-store records, Repo process reopen and three separate OS-process reconstructions through scoped HTTP | Controlled backend; no held native-session refresh claim |
| Actual saved client calls | #807, eight controlled native comparisons | Three MCP reads become one; backend calls remain three; no general latency/token/quality gain |
| Protocol catalogs and reconnect | Controlled real Snodo HTTP proof plus installed Codex nonpaid status and Claude health checks | Claude catalog contents, native prompts and held-session notification refresh remain unknown |

The implementation budget is consumed by the shipped dispatcher/store slice and
its bounded native proof. #799 retains protocol/native compatibility acceptance;
#577 concludes its bounded first-proof design spike with the fixed dispatcher as
the chosen transport. Versioned definitions, scoped activation/discovery/invocation,
denial, partial failures, reconstruction, replacement, disable and rollback have
bounded evidence. Individual dynamic publication, mining and write activation
remain deferred. This decision retains the explicit opt-in composition; it does
not establish general quality improvement or authorize a third production
extension slice. The desired future synthesis loop remains outside this proof.

## Original bounded slice plan

1. Add one opt-in `pr_review_context` composition through shared operations with
   immutable definitions/activation, trace refs, exact caller propagation,
   bounded output, explicit source-coherence limits and one owner's discovery.
   Fixed compiled dispatcher and schema validation first; original reads remain.
   Prove permission changes, restart, disable and rollback on real Snodo clients.
2. Exercise real Claude/Codex use against the original sequence and measure calls,
   correction rate, context bytes and available usage. Separately test negotiated
   tool/prompt/resource catalogs, notifications and reconnect before publishing
   individual dynamic entries. Retain unknowns where a host does not expose them.

Only promote a composition when it preserves correctness and saves actual work.
No marketplace, secondary workflow engine, transcript miner or privilege by
model-generated classification is part of these slices.
