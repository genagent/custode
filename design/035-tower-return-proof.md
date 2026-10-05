# 035: Tower decision continuity through production subject reads

Status: implemented controlled acceptance proof, closes #834, refs #785.

The standalone fixture proves the full Tower finding and decision scenario, but
production return-view tests use a literal PR-reference label. Add a focused
production fixture retaining a synthetic dated finding, a human-owned decision
and a verified PR URL as data. The test does not assess that remote PR.

Use existing SubjectDocuments, ReturnViews and actual authenticated MCP HTTP
operations on both supported dialects. Remove the producer and its workspace;
read both current documents through an authorized fresh identity. Keep current
decision/source revisions distinct from immutable publication and authored report
facts. External decision edits must force reread/reanchor for old feedback while
historical server-emitted receipts keep the exact earlier tool text.

Files: new test/custode/tower_return_flow_test.exs and this proof note. No changes
to production authority, policy, source apply, UI, migration or MCP schema. No
paid inference, provider CLI, native/model-consumption evidence, remote PR
assessment, automatic acceptance, job enqueue or fleet deployment.

Run all five gates before plan and implementation pushes. Run meaningful focused
fixtures under seeds 1, 12345 and 777. Obtain independent review, integrate merged
#833 before final publication, and require four successful CI checks on the exact
updated head. Preserve the inactive worktree's caches and private evidence.

The two dialect fixtures use a new authorized helper identity after producer
cleanup. They assert dated synthetic source content, the human-written decision
and PR reference, current output/detail revisions, original producer/owner facts,
historical server-emitted bytes after an edit, stale feedback refusal and explicit
receipt expiry. Job assertions cover only the fixture's unique owner/helper ids.
No production module or shared authorization is changed.
