# Deterministic GenAgent host adapter proof

Implementation plan for #880, a bounded fixture slice of #777.

Build a standalone Mix project here with a disposable SQLite/Ecto journal,
real Oban delivery, gen_agent supervision, and a synthetic Claude CLI through
the wrapper/Forcola runner. Custode's application, roster and production
dependencies stay unchanged.

## Boundaries

- A1-A4: pause before admission, admission before pause, uncertain start gap,
  duplicate delivery and stale permits.
- B1-B4: waiter death during execution, before result commit, after settlement,
  and conservative recovery when result evidence is lost.
- C1-C4: terminal result before child exit, misleading stop acknowledgments,
  observed native stop, and abrupt owner death or escaped descendants.

Use explicit barriers and independent process/effect observations. Native
identity, terminal outcome and quiescence are separate facts. A conservative
hold is not a claim that automatic native recovery has been qualified.

## Validation plan

Run the deterministic cases with seeds 1, 12345 and 777. Run formatting,
compilation with warnings as errors, Credo, tests and Dialyzer before pushing.
Retain a scenario matrix and exact dependency/configuration identity.

## Operating note

This standalone proof does not change production schemas, prompts, runtime
admission or schedules. Do not restart or migrate the fleet. No real Claude or
Codex invocation, live smoke, automatic delegation, provider credentials, UI,
MCP expansion or team execution is part of this work.
