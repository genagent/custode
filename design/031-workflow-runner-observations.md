# 031: Selected workflow runner observations

Status: bounded host-observation implementation, refs #750.

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

## Implementation boundary

Only a current selected NodeJob with exact stored arguments, metadata,
generation and executing attempt 1 can record a request. The decorator delegates
unchanged to released Forcola; the wrapper builds the actual argv. Resolved
binary/argv/cwd and deadline are private request facts, not CLI version or
successful spawn evidence. Caller environment overrides are refused for this
profile; inherited environment remains unattested. No global runner setting is
changed during a query.

The first request prevents a second delegation for that job attempt, including
when the first return is unknown. The first transport return can be attached
only from its process-local invocation token and cannot be rewritten. A late
return remains history of its captured generation and changes no run or result.
Exceptions and killed owners leave an unknown return. Normal and observed
session execution and streaming outside selected scope still delegate directly.
The private request accepts at most 256 argv entries and 1 MiB of combined
serialized request and execution binding. Exceeding either bound refuses before
persistence or delegation with observation unavailable. Accepted commands pass
to Forcola unchanged. The shared retry read exposes at most 100 summaries, with no raw command or
output values; retry remains unavailable. Observations retire with finished
workflow runs under the existing retention rule.
