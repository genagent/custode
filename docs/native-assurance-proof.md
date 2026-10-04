# Bounded native assurance proof, 2026-10-04

Status: native evidence for #795; actual human approval and all-descendants
settlement are not established. The designated judge is the explicitly synthetic
host proof harness. Every decision retains `effect_authority=none`.

Two actual Claude Code 2.1.284 producers emitted `claude-sonnet-5-5` and wrote the
fixed wrapper. Two actual Codex 0.157.1 cold verifiers ran the pinned check from
separate physical worktrees, then returned independently bound opinions. Codex
requested `gpt-5.5` with low effort; its stream did not identify the actual model.
Both CLIs received explicit low effort; observed effort remains unknown.

| Case | Actual artifact commit | Check | Opinion | Harness decision |
| --- | --- | --- | --- | --- |
| clean | `2355a359100029ed044b52565098bc7c76aaa666` | passed | passed | accepted |
| seeded | `761acbb820a2a1bab3d674c31619f82bbf37c798` | failed | failed | rejected |

The fixed checker reruns ten addition/wrapper rows against exact artifact and
checker digests. The host seeds subtraction in the defective baseline and owns
fixture and artifact Git commits. Provider authorship is limited to the wrapper.
The harness deliberately records a passed judge for both cases: the seeded
check/opinion contradictions remain visible and force rejection.

## Corrections and receipt history

The four completed native calls ran source `98a64f7e2227f7f5aee200430294d398783cab47`.
Initial capture remained conservative: Codex combined the fixed JSON with a
macOS Git temp-directory warning and called its nonzero command terminal `failed`.
The clean decision escalated and both check receipts stayed unknown.

Nonpaid reassessment at `1ee3b561e3d04f0453df73500a7bd92833c80034` accepted only one bound
JSON frame, optionally preceded by that exact retained diagnostic, and a coherent
failed/nonzero command terminal. Ambiguous JSON, unknown diagnostics, conflicting
identities or terminal status and wrong command/cwd/artifact remain unknown.
It created new check receipts and decisions from the immutable retained records;
it preserved the old unknown receipts and original decisions. It launched zero
native calls and verified that all native records were unchanged.

Three earlier attempts are retained explicitly: Claude's variadic argument parser
consumed the prompt; a corrected launch emitted a native initialization then an
authentication error because non-secret `USER` was
filtered; a later real Claude producer succeeded but Codex waited on open stdin
and timed out before emitting a session or command. Each correction was manual
in a fresh store/workspace. The final four-call run plus the diagnostic producer
are five successful model runs, with no automatic retry. Account usage and cost are omitted from this public report and retained privately.
Codex cost remains unknown. Claude's USD 0.5 setting is a configured budget stop,
not a hard total-billing ceiling.

## Retention and bounds

[`priv/assurance_native/native-proof-results.json`](../priv/assurance_native/native-proof-results.json)
retains native versions, consistent SHA-256 aliases for session ids, requested/observed model,
command exits/output, exact base/artifact/case/policy bindings, evidence/decision
ids, old receipts and decisions, manual failures and source/private-record hashes.
Original session identifiers, usage/cost, raw streams and the SQLite store remain private; raw output is bounded
to 512,000 bytes per launch. Public native paths are placeholders. Session aliases also replace embedded run-id
components, preserving equality and distinction without exporting native identifiers.
Source file hashes identify the snapshots even after
integration rebases or squash merge.

All six bounded controls pass: identical native request replay, duplicate capture,
stale refusal, round bound, effect authority none and SQLite store-process reopen
with recapture from copied actual native rows. This is not a full VM restart proof.
Nonpaid tests also kill a launch owner and confirm that its unresolved workspace
reservation prevents redelivery and a different request cannot take that workspace.
Native exit and observed-descendant cleanup do not attest all escaped descendants;
that missing attestation is explicit and workspace reservations never expire on
terminal status alone. This fixture does not establish general sandbox confinement,
general provider correctness or actual human acceptance.

## Deliberate reproduction

Create a private TMPDIR and use a fresh direct-child root. Ordinary tests use
synthetic executable fixtures and never call paid providers.

```sh
mkdir -m 700 /private/tmp/custode-native-795
TMPDIR=/private/tmp/custode-native-795 CUSTODE_TEST_MCP_PORT=6182 \
MIX_ENV=test CUSTODE_NATIVE_ASSURANCE_PROOF=1 \
mix custode.assurance.proof --root /private/tmp/custode-native-795/proof \
  --claude-model sonnet --codex-model gpt-5.5
```

Models must be available to the native account; the explicit model options are
experimental selections, not new defaults. Each call has a 90-second deadline,
with four calls configured per initial run and no automatic retry. To reassess
retained streams after a recorder correction, use the same guarded invocation
with `--reassess`; it requires a private existing proof store and calls no provider.
Observe the same-instance boot cooldown. Neither path starts a fleet or authorizes
application, publication, gate approval or merge.
