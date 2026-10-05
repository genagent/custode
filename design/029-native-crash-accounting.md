# Native crash evidence accounting

## Plan

Record the outcome of the operator-approved pair of isolated native crash runs
for #795 and #710. One Claude producer and one Codex verifier use the existing
reviewed controller. Recovery makes no model call; no automatic retry, workspace
release or effect authority is introduced.

Update the existing proof documentation with anonymous provider/failure/status
and Boolean recovery controls. Keep raw captures, native identities, capture
hashes, account telemetry and detailed bindings private. A failed case is retained
as a failure, and no new provider request is added to make it pass.

Compare the observed outcomes with the issue's pinned-case and reconstruction
requirements. Close a parent only if its named proof requirements are met; retain
missing provider behavior, physical settlement or acceptance explicitly. This is
an evidence update, not a third production extension.

Expected files: this accounting note, docs/native-assurance-crash-proof.md and an
anonymous result projection. All five gates before each push, independent review
of the actual private bindings and exact updated-head CI. No migration, prompt,
production operation, permission, scheduler or automatic merge change.


## Result and decision

Exactly two operator-approved actual native launches passed, with no retries.
The interrupted Claude worker retained an incomplete row; the interrupted Codex
owning BEAM retained a running row. Fresh OS-process recovery passed all eight
controls in each case and made zero model calls. Original frozen contexts, native
rows, source snapshots and anonymous projection were independently reviewed.

Combined with the retained actual clean/seeded cold cross-provider checks and
prior fresh-process reconstruction, no original named bounded first-proof
predicate remains unmet. Close #710 and #795 for that proof. The selected judge
remains synthetic. Human acceptance, general inference quality, physical
all-descendant settlement, safe retry, reservation release, effect authority and
machine reboot remain unproved or unavailable. This result neither grants them
nor authorizes another model run.

Only anonymous outcome facts and the pinned public Git source revision are added
to the public report. New native identities, session aliases, capture hashes,
account telemetry, private paths and raw output stay private. The earlier
synthetic exercise remains separate and unchanged.
