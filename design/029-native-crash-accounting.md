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
