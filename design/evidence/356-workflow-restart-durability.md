# Workflow restart durability exercise (#356)

Date: 2026-07-29

This is execution evidence for the workflow machinery that `design/008` may
later link to Attempts. It does not change that contract, add schema, or route
new entry points.

## Setup

The exercise used the real `Custode.Workflow.Run`, `Results`, `Runner`,
`NodeJob`, Oban Lite, `Custode.SpendLedger`, feed, Claude CLI 2.1.220, and
report writer. It ran against `genagent/custode` with:

- an isolated SQLite database and artifact directory under `/tmp`;
- only the Repo, migrations, spend telemetry, and workflows queue started;
- no scheduler, routines, agents, MCP servers, or web endpoint;
- workflows queue concurrency 1 and the production 20-minute Lifeline;
- a $1 per-node Claude cap;
- an operator-approved total exposure ceiling of $15.

No workflow-produced output was published or filed externally.

Two runs were needed. The built-in `deep-report` supplied the realistic
restart and failure evidence. A two-stage `durability-probe`, injected through
the existing `:extra_workflows` catalog test seam and not added to the
repository, isolated the budget-pause and final-artifact assertions after the
built-in run exposed a blocker.

## Built-in workflow restart

Run `issue-356-deep-report-20260729` launched `deep-report` with a $2 run rail
and this subject:

> whether Custode workflow execution should map to one Attempt, an Attempt
> group, or a linked execution plan

The first `search` node, `prior_art`, completed at $0.9838347. A telemetry
handler paused the workflows queue before another job could start. After its
callback persisted, the interruption point contained:

- run status `running`, stage `search`;
- one result keyed by
  `{prior_art, 3fa579328cc9546237d568add1710805e14a2a8f7ed8be385e4f98fa5b8f55b8}`;
- one completed Oban job and three available sibling jobs;
- one spend row;
- no duplicate result keys.

The runtime then stopped. On a fresh runtime over the same database:

- the run, result, job, and spend row were unchanged before `resume_all/0`;
- `resume_all/0` returned the existing running run;
- `prior_art` did not enqueue or execute again;
- `practice` executed next and added one result and spend row.

This demonstrates resume from persisted state and no repeat payment for the
completed node.

### Failure found

The third node, `sources`, crossed the Claude per-node cap. Claude reported
$1.0764216 and `{:cancel, :max_budget_exceeded}`. The run correctly became
`failed`, but the queued `dissent` sibling moved to `executing` after the run
was terminal.

That call was stopped manually. The job row was later set to `cancelled` in
the isolated evidence database so the probe could reuse the database safely.
The observed pre-cleanup state and defect are recorded in
[issue #387](https://github.com/genagent/custode/issues/387). The fix and
re-exercise below close this blocker.

The built-in run retained enough evidence to explain its outcome:

- status `failed`, stage `search`;
- error `node sources failed: {:cancel, :max_budget_exceeded}`;
- unique results for `prior_art` and `practice`;
- completed, completed, cancelled, cancelled final job states after cleanup;
- three spend rows totaling $2.9480726;
- `workflow_launched` and `workflow_failed` feed entries.

The CLI cap is a stopping threshold, not an exact accounting limit: the
reported failed call exceeded the nominal $1 cap by $0.0764216.

## Budget pause, explicit resume, and artifact

Run `issue-356-durability-probe-20260729` used two sequential Haiku nodes:
`seed`, then `report`. Its initial run rail was $0.001, deliberately below one
minimal real call, while retaining the same $1 per-node cap.

`seed` completed for $0.080505. Before `report` was enqueued, the runner:

- moved the cursor to `synthesis`;
- set status `budget_paused`;
- recorded `paused before report` in the run notes;
- emitted `workflow_stage_complete` and `workflow_budget_paused`;
- left no pending report job that could spend while paused.

A fresh runtime then called `resume_all/0`. It returned `[]`. Three seconds
later the run, one result, one completed job, and one spend row were unchanged.
The paused run did not resume without operator action.

The run was explicitly unpaused with a $1.50 rail, then `Runner.resume/1`
enqueued `report`. That node completed for $0.081356. The final state was:

- status `complete`, no stage cursor;
- two unique results and two completed jobs, each attempted once;
- two spend rows totaling $0.161861;
- no duplicate `{workflow_run, node_name, args_hash}` result keys;
- the budget-pause note retained as history;
- completion and report feed entries;
- report artifact at the configured run artifact directory.

The report contents were:

```markdown
# Issue 356 durability probe

Restart resume, explicit budget unpause, and artifact writing completed.
```

Its SHA-256 digest was
`e47b96977297c0b570d47d0132db9b8ed0dcaddbb6792bfff6a9ace6d965c6f6`.
The `report` result row referenced the same path written by
`Custode.Workflow.Report`.

## Terminal-failure cancellation re-exercise (#387)

The #387 fix reused the runner's run-scoped pending-job cancellation when a
node fails terminally. A fresh isolated runtime exercised the exact paid-call
race with one stage containing two Haiku siblings:

- `fails_first` had a deliberately microscopic $0.001 per-node cap;
- `must_not_start` was queued behind it;
- the run rail was $1, so only terminal node failure could stop the stage.

`fails_first` returned `{:cancel, :max_budget_exceeded}` at $0.0496291. The run
became `failed`, the failing job became `cancelled` after one attempt, and
`must_not_start` became `cancelled` at attempt zero. The state was unchanged
after a one-second settling window. The spend ledger contained exactly one
row, for `fails_first`.

This directly demonstrates that an available sibling no longer begins paid
work after the run becomes terminal. The focused regression test additionally
covers available, scheduled, and retryable sibling states, another workflow
run remaining untouched, and a repeated terminal callback.

## Spend

Recorded spend was:

| Run | Rows | USD |
| --- | ---: | ---: |
| `deep-report` | 3 | 2.9480726 |
| `durability-probe` | 2 | 0.1618610 |
| Total recorded | 5 | 3.1099336 |

An early harness attempt used an invalid 30-second Lifeline and was discarded.
That Claude process was stopped manually and the harness was corrected to the
production 20-minute value. The `dissent` process from the real defect was also
stopped manually. Conservatively charging both unrecorded calls at their full
$1 caps puts maximum total exposure at $5.1099336, below the approved $15.

The early harness database was retained separately under `/tmp` and did not
contribute evidence to the assertions above.

The #387 re-exercise added $0.0496291 of recorded spend. Across #356 and #387,
recorded spend was $3.1595627 and maximum exposure under the same conservative
accounting was $5.1595627, still below the approved $15.

## Attempt mapping decision

A workflow run does not map cleanly to one Attempt.

The observed unit that owns one invocation, one per-call cap, one Oban
attempt, one terminal outcome, one spend row, and one result is the node job.
The `deep-report` run contained successful nodes and a failed node, while the
run itself owned stage barriers, a run-level rail, pause/resume state, and the
final aggregate outcome. Treating that whole run as one Attempt would hide
the independently bounded executions and their mixed outcomes.

The narrow interpretation for the Attempt successor is:

- one paid `NodeJob` execution maps to one Attempt;
- the workflow run is a linked execution plan or Attempt group;
- stage and dependency order belong to that plan;
- node results become outputs of their Attempts;
- a final report remains an Artifact produced by the report Attempt and linked
  through the plan.

This is evidence for #363, not an implementation of it. The #387 fix prevents
the paid sibling work observed here; the Attempt successor can use the mapping
above without importing workflow-run state into one oversized Attempt.

## Operational risk

A hard VM abort while Claude is executing can leave the external CLI process
alive. The clean restart exercised here interrupted only after a node result
had persisted and the queue was paused. Operator-managed restarts should keep
using the existing drain path from #132. Hard-crash recovery and the
20-minute Lifeline remain at-least-once for an in-flight node; the durable
result key prevents duplicate persistence, but cannot refund duplicate paid
execution that began before a result existed.
