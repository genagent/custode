# Opt-in PR read composition

The fixed `read_composition` dispatcher combines existing served-repository reads.
It runs no model, generated code or shell and confers no write or approval grant.
Original `repo_view_pr`, `repo_pr_checks` and `repo_pr_diff` remain available.

Set `CUSTODE_READ_COMPOSITION_OWNER` to one current standing routine id before
starting Custode. Its current roster repository is the only composition repository.
Changing or withdrawing the owner/repository disables access, including old client
connections. Helpers and other routines cannot discover the dispatcher. The human
operator can inspect/configure through the same application operations and MCP.

## Publication

Use `read_composition_configure` with a JSON `request`. The CLI equivalent is
`mix custode read-composition request.json --json`, which selects the same MCP verb.
The CLI targets an existing server; do not start a second instance for it.

1. `publish` carries a definition with exactly `name`, `repo`, `description`, and
   `steps`. The name is `pr_review_context`. Each step is `{ "tool": NAME,
   "arguments": { "repo": { "$arg": "repo" }, "number": { "$arg": "number" } } }`.
   Names may be `repo_view_pr`, `repo_pr_checks`, `repo_pr_diff`, with no duplicates
   and at most three steps. `Custode.ReadCompositions.template(repo)` is the source
   template. Import is inactive and does not turn source into executable code.
2. `activate` carries `name`, the published `revision` and `expected_generation`
   (initially 0). The immutable revision includes the compiled contracts and exact
   dependency fingerprints. Stale generations are refused atomically.
3. `disable` carries `name` and `expected_generation`. Rollback uses `activate` with
   an earlier immutable revision and the current generation. Every pointer update
   increases generation, even a return to the same revision.

## Invocation and limits

`read_composition` takes `request` actions `list`, `invoke`, or `trace`.
`invoke` names `pr_review_context` and `arguments: { "repo": "owner/name",
"number": 123 }`. `trace` takes the returned `trace_id`. Discovery lists only active
logical definitions whose current scope is available. The human list also returns
the current activation pointer, including disabled generations, so a lost HTTP
reply does not require blind writes or direct SQLite inspection.

Each read rechecks the verified caller's current capabilities, owner/repository,
activation generation and compiled dependency revision. An intervening disable,
replacement, rollback or grant change stops the next dispatch. Earlier results
remain in the response. A dispatched read's bytes cannot be retracted. Upstream
errors are summarized without copying possibly sensitive error payloads into traces.

Responses state the limit: PR fields and checks may describe different heads, and
the diff has no pinned head. This is useful aggregation, not an atomic snapshot or
verification verdict. Matching head values would not prove snapshot consistency.
At most 100 check/file rows, 20KB per read value and 60KB total values are returned.
These are output bounds; upstream clients may allocate larger responses first.
The latest 100 terminal traces contain actor/revisions/digests/outcomes and byte
counts, not raw arguments or results. Pending traces survive crashes as uncertainty;
ten unconfirmed invocations exhaust admission instead of silently re-running them.
Investigate retained pending records before operator maintenance clears capacity.

## Operating note and proof

This adds `composition_records`. Drain/stop the old instance, pull, migrate and
restart before opting in. Nothing is activated by default; no prompt is changed.
New tests cover both supported HTTP protocol revisions using real Snodo clients
against controlled repository fixtures. They prove protocol and application
contracts and durable activation across a supervised SQLite Repo process restart.
The opt-in nonpaid `mix custode.composition.proof` task also reconstructs the actual
operations store in three separate OS processes, exercises scoped HTTP reads and
denial, and retains replacement, disable and rollback. See the
[native and reconstruction proof](native-read-composition-proof.md) for its limits.
#577 concludes the bounded design spike with the fixed dispatcher; #799 retains
held native-session refresh and broader benefit acceptance. Individual dynamic
publication and automatic synthesis remain deferred.
