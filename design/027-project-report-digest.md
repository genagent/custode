# 027: Central project-report digest

Status: implemented bounded read projection for #815.

The manager needs one bounded view of project accomplishments, blockers and
operator decisions. Interval reports already live in the durable Feed and
project_progress exposes them to the operator and caretaker. Keep those
records authoritative; this is a read projection, not a second status store.

## Implementation plan

- Add one shared authorized project-report digest over retained turn records,
  configured owners and existing attention/ask/gate reads.
- Bound both project and report counts and make the time window explicit.
  Keep agent-authored report claims distinct from observed execution facts.
- Show older unresolved blockers/decisions independently of the report window.
  Preserve timestamps and stable source links; missing/stale is not quiet.
- Reuse a compact semantic-theme component on the manager surface. UI reads
  the same projection exposed by one authenticated MCP read tool.
- Update ToolPolicy, capability inventories, behavior notes and generated
  client references. Cover scope refusal, windows, limits, legacy reports,
  duplicates, restart reading and UI integration with focused tests.

## Validation and operation

Run format, warnings-as-errors compilation, strict Credo, the full suite and
Dialyzer before each push. New focused tests run under seeds 1, 12345 and 777.
Read the finished diff against #815 and require CI on the updated main head.
This slice adds no scheduler, outbound notifications, automatic wake, approval,
new task board or external project ingestion. It does not broaden workers'
read access. A running fleet needs a pull/restart; no migration is planned.

## Delivered contract

The project_report_digest MCP read and manager conversation use the same
ProjectReportDigest operation. Only the operator or current captured caretaker
role may read it. This does not add worker or helper access.

The default window is 24 hours, with at most 25 configured owners and one
report each. Callers may request 1 to 168 hours, 1 to 50 owners and 1 to 3
reports per owner. Time boundaries are inclusive; future rows do not affect
report freshness. Ordering is stable by recorded timestamp and row id.
Each owner also shows up to three current open asks and gates per kind,
independent of the report window, with truncation flags.

Latest retained typed-report concerns can predate the window; their resolution
is not established by this view. A newer typed report may no longer state
them, while actual open asks/gates remain visible independently. No lexical
matching or agent-reported completion resolves an obligation. Missing reports
are explicit; updates older than 48 hours are stale. Neither establishes
inactivity. Legacy summary-only and failed turns retain honest provenance.

Configured owners only are included, with omission counts when a caller's
limit cuts the list short. Removed owners and fleet-wide infrastructure
remain visible in Inbox; the overview links there rather than implying the
project digest is a complete inventory of human obligations. Execution facts
and decisions are independent current reads, not an atomic snapshot.

The manager's Project digest link opens a folded overview beside its existing
conversation. Source links keep direct owner conversations reachable. The
read never starts a model, polls an owner, acknowledges a message or creates
a scheduled morning notification. Such delivery can consume this operation
when its cadence and destination are selected.
