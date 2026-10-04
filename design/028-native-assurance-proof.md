# 028: Bounded native cross-provider assurance proof

Implementation plan for #795.

The first assurance record slice is deliberately conservative: existing review prose has no native verifier identity and cannot satisfy independent reproduction. This proof adds a recorder-owned native source seam and tests it against two fixed repository cases.

Plan:

- Add a bounded internal native recorder and generated `assurance_native_*` SQLite records. Only configured launch profiles identify executable/provider/model/effort, eligible actor, workspace, exact case generation and command contract. Observe actual native session ids, raw stdout/stderr, requested versus emitted model, exact argv/config revision and command exits/output. Caller-supplied source labels or imported manifest claims do not establish trust.
- Extend the assurance source-reference adapter and frozen producer reference for those observed records. Issue reproduction only for an independently identified other-provider execution whose emitted command actually ran the pinned check against the frozen artifact. Keep authored findings/opinion separate from deterministic command evidence. Missing identities and bindings remain unknown.
- Add one explicit proof Mix task, fixture and retained result manifest. It uses isolated worktrees/database/TMPDIR and does not start a fleet from the primary checkout. Freeze objective, base, criteria and policy before producing, then retain a bounded artifact revision. Host-seeded defect bytes and recorder-created Git commits are explicitly attributed to the harness, not to provider authorship.
- Bound the initial live proof to four calls: Claude Sonnet producing worker and cold Codex verifier using a verified available native model with low effort for each clean/seeded case. Claude has a configured budget stop, which is not a hard total-billing ceiling; Codex has time/call limits and no claimed hard dollar cap. No automatic native retries. The verifier receives the exact artifact and criteria without the producer's conclusion.
- Retain accepted clean and rejected seeded outcomes under a clearly named host proof-harness judgment, visible disagreement, generation/round bounds, duplicate/conflicting delivery and stale refusal. Harness judgment is a synthetic boundary and never represents actual user approval. Reopen the SQLite store and reconstruct exact evidence/decision links.
- Exercise crash/redelivery with owned-process observations. Existing runner cleanup tracks observed descendants and does not attest escaped descendants. Record missing all-descendants attestation explicitly; terminal job/native status alone never admits replay. Any unresolved physical settlement remains a failed or limited proof condition.
- Add deterministic adapter/receipt tests under seeds 1, 12345 and 777. Paid providers run only through the explicitly invoked proof task, never the ordinary test suite. Run all five repository gates before every push and exact-head CI before readiness.

Likely files: `lib/custode/assurance/`, `lib/custode/assurance.ex`, one `lib/mix/tasks/custode.assurance.proof.ex`, generated migration, test truncation list, focused assurance native tests/fixtures, `docs/assurance.md`, `design/028-native-assurance-proof.md`, and bounded proof artifacts. If read behavior changes, review MCP behavior notes and regenerate the reference.

Out of scope: transport replacement, full host-adapter adoption, generic task board/mesh, kernel activation, deployment, automatic effect authority or merge. Native execution correctness does not imply human approval or general provider correctness.

## Operating note

The planned recorder adds an operations-store migration and an explicit opt-in native launch path. A running fleet requires pull, migrate and restart for the source seam. No paid run is enabled by default and no ordinary test launches a model.

Refs #795. The proof must identify remaining human-approval or physical-settlement limits before claiming full completion.
