# 031: Selected workflow runner observations

Status: implementation plan, refs #750.

The tool-free definition contract captures requested wrapper options, but no
record currently identifies the actual command delivered to the released
transport runner. Add durable observations for new selected jobs only.

## Changes

- Add a generated migration and `Workflow.ExecutionObservation` storage for
  immutable first delegation request and first transport return, bound to the
  exact stored NodeJob, attempt, generation and result-contract digest.
- Add a trusted Claude runner decorator over the fixed released Forcola runner.
  Bind selected NodeJob execution in process-local scope, cleared after the
  query. Preserve ordinary run, observed session and stream delegation.
- Retain resolved command arguments privately, with environment override and
  output digests rather than their values. The request records delegation only;
  absence of a return remains unknown after exception, owner death or restart.
- Add bounded sanitized observation summaries to the shared RetryStatus read,
  keep retry unavailable, and update MCP behavior/reference notes.
- Retire observations with their finished workflow run; add test truncation.

Implementation files: config/config.exs, lib/custode/workflow/node_job.ex,
new workflow execution-observation and Claude-runner modules,
lib/custode/workflow/retry_status.ex, lib/custode/janitor.ex,
priv/repo/migrations, test/test_helper.exs, focused workflow tests,
docs/mcp/behavior.json and regenerated client references.

## Validation

All five gates before every push: formatting, warnings-as-errors compile,
strict Credo, full tests and Dialyzer. New meaningful fixtures run under seeds
1, 12345 and 777. Exercise the actual worker and released argument builder;
refuse stale job/generation/input/attempt and conflicting observations; preserve
first records and default delegation; retain unknown return after exception or
killed owner; check privacy, bounded reads and workflow retention. Use controlled
nonpaid transports only. Obtain independent review before readiness or merge.

## Limits

No paid model calls, fleet deployment, catalog opt-in, policy widening or retry
admission. A delegation request is not successful process spawn. A transport
return is not native confinement or physical settlement. The released wrapper
loses detailed timeout evidence, so it cannot be reconstructed. Inherited
native environment, CLI version and all-descendant containment remain
unattested. #750 stays open.

## Operating note

A future running installation needs pull, migrate and restart for the new
observation table and trusted runner decorator. This work performs no fleet
migration or restart and changes no prompt files.
