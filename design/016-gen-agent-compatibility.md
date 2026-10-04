# 016: Released GenAgent compatibility

Status: bounded proof for #752, 2026-10-04. No-go for standing-runtime adoption
until host integration contracts below are proved. Keep Oban and the current
runtime. #596 and #708 do not wait for this migration.

## Version and API map

Source reviewed at upstream 7ce6250650224bab8fffacd2641b3e4f1ce6147c and release
tags. The standalone proof pins the packages it executes, not upstream main.

| Package | Released version | Usable boundary | Remaining host responsibility |
|---|---|---|---|
| gen_agent | 0.6.2 | Streaming backend, correlated completion, active-turn checkpoint callback, interruption, bounded runtime snapshot | Durable checkpoint/restore, per-turn exact execution policy, normalized durable projections |
| gen_agent_claude | 0.2.5 | Captured model/effort/tools/limits, session checkpoint, explicit resume helper | Correlate early id with durable admitted turn; rebuild safely when approved options change |
| gen_agent_codex | 0.4.8 | Captured exec/sandbox/schema options, thread checkpoint, explicit resume helper | Preserve resume-option constraints and known/unknown cumulative usage baseline |
| gen_agent_ensemble | 0.6.1 | Pool and other strategies, correlated completion, poll/await/cancel | Durable parent/child records, aggregate admission, external settlement |

Core 0.7.0 is pending in upstream PR 313. External stream_to, list/0 and response
metadata improvements on main are not evidence for core 0.6.2. Upstream issue 192
tracks per-turn backend options. The released prompt/3 context contains checkpoint,
not grant-derived model, effort, schema, tool policy or turn caps.

Claude's json_schema option is JSON text; Codex's output_schema is a file path.
Their options and effort names must be mapped individually. Codex's released
adapter rejects enabled fresh-only cd/add_dirs/search/ephemeral options on resume
rather than silently dropping them. Resume usage may have an unknown baseline;
unknown is not zero and a restored thread does not authorize new work.

## Current Custode boundary

Custode.Agents routes the sole live provider. RoutineTicks and ProviderJobs retain
Oban admission/delivery, configuration revision and generation/turn identities.
Feed.Ingest, SpendLedger, Availability and ExecutionFacts consume provider facts;
OperatorMessages requires exact receipt correlation. OneShotJob, SubAgents and
Workflow.Runner also depend on the current providers. A scan found 25 production
and 59 test files with direct ObanClaude/ObanCodex/ClaudeWrapper/CodexWrapper
references, including frozen code. This is an inventory, not a migration estimate.

Do not replace a durable job with an in-memory GenAgent token. Oban retry must
reconcile the recorded logical attempt, not invent another provider prompt.
Pause/drain, admission and owned-checkout barriers must remain outside an adapter.

## Executed proof

See spikes/gen_agent_compatibility. Six tests pass under seeds 1, 12345 and 777.
The released core accepts an early native id before failure and rejects a stale
checkpoint after cancellation. A host fixture persists that id before completion
and restores it explicitly on reconstruction. Core restart itself loses it;
runtime_snapshot excludes backend_session and core never invokes resume_session.

A completion call given new model/tool options still launches with captured
backend options. The fifth call argument configures core behavior, not per-turn
provider authorization. Treating it as grant application would be a silent error.
Ensemble tests establish independent parallel results, partial failure and
duplicate/late callback fencing. They prove BEAM coordinator behavior only.

No actual provider CLI, live policy, durable Custode restore or approval
continuation was tested. Fixed-profile reconstruction demonstrates an available
seam, not complete canary parity. Session initialization events are not exposed
as ordinary normalized events in this release.

## Decision and implementation boundary

A narrow host adapter is plausible; changing dependencies now is not sufficient.
First implement and prove, behind Custode.Agents:

1. Persist an early native id with provider, configuration revision, generation,
   logical turn and receipt. Refuse stale observations; restore only that admitted
   execution without replaying completed input. Preserve Codex usage baseline.
2. Apply the exact effective grant/model/effort/schema/limits before process launch.
   Either extend per-turn backend options or reconstruct at a proven quiescent
   turn boundary. Preserve native continuation while fencing old callbacks.
3. Normalize completion, usage, rejection, cancellation and shutdown to existing
   durable projections. A cancellation acknowledgment is not external settlement.

Only then offer an opt-in fixed-profile canary for each provider, retaining the
current runtime by default. Standing routines, one-shot jobs/workflows and test
cleanup follow measured adapter scope. The proof is about 200 lines of fixtures;
it is not the adapter diff. A credible migration estimate requires that diff, so
there is no replacement for the earlier unsupported four-to-six-PR estimate yet.

References: https://github.com/genagent/gen_agent/issues/192 and
https://github.com/genagent/gen_agent/pull/313. No runtime, schema or prompt change
is adopted by this note.

Implementation follow-up: #777. Owner review coordination is separately #778.
