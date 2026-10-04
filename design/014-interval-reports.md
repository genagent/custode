# 014: Interval reports

Status: implementation plan for #770.

Domain owners publish short reports for the human and caretaker. The report
is optional and separate from execution facts, direct answers and directives.

## Contract

`report` contains Done, Verified, Next, Blockers and Decisions as arrays of
short Markdown strings. Each section has at most three entries, each at most
500 characters. Empty sections may be omitted by Claude; Codex requires the
keys with empty arrays because its output schema is strict. A missing or null
report preserves legacy behavior. Unsupported fields or malformed entries
produce a visible report-validation diagnostic, without losing the turn's
existing summary, directive or answer.

Use the existing feed record as the durable report record, adding available
provider, job, correlation, execution revision and origin metadata. Correlated
duplicate completion events must not append another report. Legacy events
without a durable execution identity retain their historical behavior.

Expose recent report evidence through the existing authorized project-progress
read. Record timestamps and identity; do not claim that an authored Verified
section independently proves acceptance or that an old report is current.
Reports do not themselves wake the manager.

## Implementation and gates

Change the routine output schema and charter, add one report validation/read
module, extend feed ingestion and authorized project progress, and reuse one
report renderer on activity/turn surfaces. Update MCP behavior/reference notes.
Test provider parity, bounds, duplicate completion, legacy/failure/directive
behavior and read authority. Run all five repository gates and focused tests
under seeds 1, 12345 and 777.

## Limits

No new scheduler, approval authority, context store, assurance engine or
provider transcript. Conversation presentation is the next slice, #771.

## Operating note

This changes priv/prompts guidance. Pull and restart the fleet to apply it.
