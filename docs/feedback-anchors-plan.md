# Revision-bound span and hunk feedback

Plan for the remaining review acceptance in #785, after the bounded subject Git
surface in #810. Adapter delivery receipts in #812 remain a separate unit.

- Keep existing inclusive line feedback compatible. Add shared typed text-span
  anchors using one-based Unicode grapheme columns and an exclusive end, bounded
  selected-text evidence, and exact current working revision checks.
- Add an authorized read-only diff projection with stable hunk identities bound
  to current working SHA256, pinned HEAD, base content and diff fingerprint. Hunk
  feedback re-reads that scoped diff and refuses changed source or HEAD instead
  of attaching to a different hunk. Unsupported Git stays explicitly unavailable.
- Keep anchor validation and form parsing in shared operations. Extend the folded
  subject detail view with labelled keyboard/pointer controls for spans and hunks;
  preserve current plan/helper/owner navigation and existing comments.
- Files: new feedback-anchor helper and focused tests, ReturnViews operation/schema,
  SubjectOutputsLive thin controls, behavior/reference and return-view documentation.
  No delivery receipt implementation files or migration.
- Gates before every push: format, warnings-as-errors compilation, strict Credo,
  full tests and Dialyzer. New tests run with seeds 1, 12345 and 777, isolated TMPDIR
  /private/tmp/custode-gates-work3 and MCP port 6183 with same-worktree cooldown.

Out of scope: apply, approval, source mutation, grants, worker start/resume,
native delivery/run-binding claims, transcript mining, new store and IDE features.

## Operating note

Pull and restart to pick up the optional read and feedback schema additions. No
migration or prompt change. Comments retain historical anchor identity and confer
no authority to apply edits or approve repository actions. This advances #785;
remaining native acceptance remains open.
