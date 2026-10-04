# Admitted subject assignments and launch-bound document credentials

Refs #784 and #785. This is a bounded provisioning and execution-binding slice, not completion of native context-use acceptance.

## Behavior

The operator may admit one existing recorded helper epoch to one configured subject root, an explicit bounded list of read paths, and one create-only Markdown destination. Admission retains the root/configuration revision, helper epoch and original parent, expiry and idempotency fingerprint. It creates no directories, infers no authority from working directories or provider permission modes, and never applies changes to existing documents. Revocation and cleanup preserve published files and historical receipts.

New helpers use a host-owned enqueue wrapper around the existing Claude Agent.Job. Only that wrapper may provision an assignment credential, bound transactionally to a persisted job and its generated generation, turn, correlation and configuration identity. The immutable private per-job MCP configuration carries a random token that has only subject_context capability. The server derives identity and checks the live executing job, immutable args/meta, admitted epoch, original parent authorization, root revision, expiry and revocation at invocation. Old helper tokens gain no new rights; assignments without this launch seam remain inactive. Retries, terminal jobs, replaced helpers and altered roots fail closed.

Output receipts and document retrieval receipts retain exact host assignment/execution references separately from unknown native session attribution, provider receipt and model use. Tokens never enter Feed, reports, public MCP responses or retained normal run-context receipts. Parent execution is never accepted from a caller declaration.

## Files

- New SubjectAssignments operational service and generated SQLite migration; test-helper truncate list.
- New small helper enqueue adapter, attached by MCP start_agent using the existing provider worker and enqueue hook.
- MCP identity, capability policy, operator assignment tool, ToolPolicy and behavior/reference documents.
- SubjectDocuments grant and producer receipt integration; ContextReceipts launch-bound retrieval provenance.
- Focused service, launch, capability, stale identity/grant and immutable output tests; durable design021/022 contract notes.

## Verification and operating note

Run all five gates before each push: format check, compile with warnings as errors, strict Credo, full tests and Dialyzer. Run new tests under seeds 1, 12345 and 777. Use work3's independent test DB, port6183 and isolated TMPDIR. No paid/model calls in tests and no fleet boot from this worktree. Review the exact auth boundary independently before readiness.

Operating note: this change adds a migration and changes launch options for new helpers. A running fleet needs a pull, migration and restart; existing helpers keep their prior launch options and ordinary rights. Native controlled-worker acceptance, Codex helper provisioning, OS-level filesystem confinement, arbitrary grant delegation and automatic apply remain outside this unit.
