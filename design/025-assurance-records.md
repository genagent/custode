# 025: Scoped production assurance records

Implementation plan for #794. This slice records one opt-in owner assignment;
it never grants effect authority or activates the work kernel.

- Add `Custode.Assurance` over `assurance_records` in the existing operations
  SQLite repository. Freeze configured owner assignment, objective, input and
  artifact revisions, criteria, policy digest and revision-round bound. Retain
  immutable attempt generations, source receipts and explainable decisions.
- Capture existing owner review, execution, subject-document and repository
  references through recorder-owned adapters. Custody of provider prose remains
  distinct from verification of its claims. Absent exact issuer, execution or
  revision binding remains an explicit unknown. Caller trust labels are refused.
- Evaluate configured predicates in one shared operation. Report satisfied,
  missing and contradictory predicates, exact evidence ids and no effect
  authority. Independent predicates require observed distinct producer and
  provider execution; authored opinion cannot satisfy deterministic reproduction.
- Add a compact read-only MCP and CLI projection. Register tool policy, update
  MCP behavior notes and regenerate its client reference. Recording remains a
  shared internal operation rather than a generic agent task board.
- Add a generated migration and test cleanup table. Test revision invalidation,
  stale generations, replay/conflict, missing identity, same-producer review,
  contradictions and persistence with deterministic source fixtures. Run seeds
  1, 12345 and 777, plus all five repository gates before every push.

Out of scope: native provider proof (#795), model launches, paid test calls,
automatic acceptance effects, apply/merge, retry settlement and kernel intake.

Operating note: adds an operations database migration. A running fleet needs a
pull, migrate and restart to expose these opt-in records.
