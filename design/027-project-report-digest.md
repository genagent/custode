# 027: Central project-report digest

Status: implementation plan for #815.

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
