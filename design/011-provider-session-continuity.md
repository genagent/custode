# 011: Provider session continuity belongs to a work arc

Status: decision, 2026-09-23. Tracking issue: #646. Implementation follow-ups:
#651 and #652.

## Decision

Custode uses a hybrid session policy. A provider session belongs to one
bounded conversational or work **arc**, not to a routine forever and not to
every individual turn.

Custode-owned records and declared context files remain authoritative. A
Claude session or Codex thread is an opaque, host-local acceleration that can
improve continuity inside an arc. Losing it may cost time or fidelity, but
must not lose an approval, question, result, plan, decision, or durable fact.

The defaults are:

| Workload | Provider session default | Arc boundary |
| --- | --- | --- |
| Scheduled maintenance sweep | Fresh | One beat |
| Interactive caretaker or subject conversation | Resume | The operator's conversational arc |
| Specialist work | Resume | One issue, assignment, or other explicit task |
| One-shot research or background job | Fresh | One assignment; resume only an interrupted instance of that assignment |
| Model Attempt | Fresh per logical Attempt | The Attempt; a deliberate repair is a new arc |
| External operator agent | Its own client concern | It reconstructs Custode state through MCP |

A question, approval continuation, rail-stop continuation, and correction to
the same active work remain in that work's arc. Finishing the assignment ends
the arc even if the routine continues to exist.

This changes design/010's simplified statement that Custode's turns are
hermetic. Scheduled sweeps remain hermetic. Interactive and multi-turn work
may use provider-native continuity while retaining a provider-neutral durable
path.

## What exists now

The behavior was traced through Custode and the released packages in use on
2026-09-23:

| Layer | Version | Existing behavior |
| --- | --- | --- |
| Custode routine | current `main` after #641 | `Routine.tick_args/1` sends `session: "fresh"` on every scheduled beat. Direct operator prompts omit that override and therefore resume. |
| `oban_claude` | 0.5.1 | Its agent state machine retains one Claude session id, resumes it on later turns, and captures ids from successes and rail stops. A fresh turn clears the one in-memory handle. |
| `oban_codex` | 0.2.0 | Its mirrored agent state machine retains one Codex thread id and sends it as `session_id` on later turns. A fresh turn clears the one in-memory handle. |
| `claude_wrapper` | 0.14.0 | Explicit resume, pinned session id, no-persistence mode, and fork are available. |
| `codex_wrapper` | 0.5.0 | Explicit resume, no-persistence mode and `exec fork` are available. oban_codex 0.5.0 exposes fork and independent resume. |
| Custode Model Attempt | current `main` | An Attempt records `provider_continuation` and a transcript reference. Later logical Attempts do not consume the prior handle. |
| Custode sub-agent | current `main` | Claude sub-agents persist a session id long enough to offer manual revival after restart. Codex sub-agent revival is not implemented. |

The wrappers therefore already preserve a conversation while the agent
process lives. Custode deliberately defeats that behavior for every scheduled
beat. The opposite path is also accidental: an operator conversation resumes
the live handle, but the next scheduled fresh beat replaces it. A process or
node restart loses the handle even though the provider transcript may still
exist on local disk.

The live `agent_status` MCP tool can return the single current session id. It
does not name the arc, say why that id was selected, or retain it when the
agent is offline. The current dashboard has the same limitation.

## Why the policy is hybrid

An indefinitely resumed routine session has no reliable task boundary. A
repository sweep may review CI on one beat and select an unrelated issue on
the next. Continuing that transcript carries stale plans and assumptions into
new work, grows the context, and binds the routine to one provider and host.

A fresh turn also discards useful state when the operator is still discussing
the same subject or a specialist is correcting the same implementation. The
provider already knows the inspected files, prior constraints, rejected
approaches, and unresolved questions. Reconstructing all of that from a
journal can cost tokens and lose nuance.

The work arc makes the choice explicit. It preserves native continuity while
the identity of the work is stable. It rotates when the work or its execution
contract changes. A compact handoff remains available for recovery and
cross-provider movement.

## Durable and provider-local state

Custode owns:

- the subject, assignment, WorkItem, Attempt, and routine identities;
- prompts and effective policy, tools, permissions, provider, model, effort,
  and workspace identity;
- gates, asks, explicit human decisions, delivery state, and spend;
- results, artifacts, notebook entries, handoffs, and authored context;
- the continuation decision and the reason it was made.

The provider owns:

- its transcript and internal compaction;
- cached tool and reasoning context;
- provider-specific conversation metadata;
- the opaque session or thread identifier used to ask for continuation.

Custode persists only enough provider metadata to make an explicit decision:
provider, opaque session id, host, canonical workspace or lease identity,
arc id and kind, configuration fingerprint, parent or fork reference,
timestamps, state, and the last continuation or rotation reason.

Provider transcripts are not synchronized into Custode. Important conclusions
must still land in the ordinary durable outputs. Native compaction may operate
inside an arc, but it does not replace a checkpoint or handoff.

## Continuation and rotation rules

Resume only when all of these match the selected arc:

1. provider and host;
2. canonical workspace identity, including the owned lease when one exists;
3. effective provider, model, effort, system instructions, policy, tool set,
   MCP configuration, and permission envelope fingerprint;
4. the same unfinished conversation or assignment;
5. an explicit provider session id that the provider can still open.

Rotate to a fresh arc when the work completes, the subject or assignment
changes, the operator asks to rotate, or any compatibility field above
changes. A provider change always starts fresh and receives a durable handoff.
A model or effort change also rotates by default so historical execution facts
remain unambiguous. Later evidence may allow specific compatible changes.

A code or document revision inside the same workspace does not by itself
rotate an active arc. The next turn must receive the current revision and
dirty-state facts and re-read changed material. Changing to another checkout
or lease does rotate.

Age and turn count are observable warnings, not automatic rotation triggers
in the first implementation. The wrappers do not expose a portable measure of
remaining provider context, and an arbitrary limit would discard useful state
without proving it had become stale. Completion and compatibility boundaries
provide deterministic rotation first. Measurements can justify a later limit.

Fork preserves an old arc while branching the same work. Use it for a risky
alternative, independent review, or a provider-context refresh that should
retain the old transcript. Use fresh plus handoff when fork is unsupported,
when compatibility changed, or when portability matters.

Never use a provider's "continue most recent session" shortcut. Concurrent
workers make recency ambiguous. Every continuation names the exact id selected
for the exact arc.

## Recovery

Custode records the intended continuation decision before launch. A successful
turn records the observed provider session id against the same logical turn
and arc.

If the process restarts while idle, Custode seeds the named arc from its stored
handle after verifying the compatibility fingerprint. If the provider reports
that the handle is missing, expired, or incompatible, Custode records a
`fresh_fallback` reason and starts fresh with the durable handoff. It does not
silently select another transcript.

If a process dies while a turn may still be executing, recovery first resolves
that turn's delivery and generation identity. It must not start a continuation
that can race a late completion. #574 and #583 own that broader invariant.

Moving to another host or provider always uses the durable handoff. A local
provider transcript may remain inspectable on the old host, but it cannot be
the only copy of promised output.

## Small experiment

The decision includes one controlled, read-only experiment on 2026-09-23. A
synthetic courier repository reproduced an ambiguous timeout followed by a
duplicate non-idempotent charge. Beat one diagnosed it and received a binding
constraint and continuation key. Beat two rejected a proposed delay-only fix,
specified the smallest repair and regression test, and repeated the key.

For each provider, beat two ran once by explicit native resume and once in a
fresh session given only a compact Markdown handoff produced from beat one.
Claude used Haiku 4.5 at low effort. Codex used the account's supported default
model at low effort. Both were confined to read-only work.

| Provider | Beat two path | Reported aggregate usage | Wall time | Outcome |
| --- | --- | --- | --- | --- |
| Claude | Resume exact session id | 98 input, 182,538 cache-read, 12,702 cache-create, 5,480 output; $0.0712 | 32.1 s | Correct; retained the binding constraint and gave the strongest requested regression test. |
| Claude | Fresh plus handoff | 41 input, 64,718 cache-read, 6,393 cache-create, 2,493 output; $0.0318 | 28.1 s | Correct and retained the key; less precise about the requested regression test. |
| Codex | Resume exact thread id | 18,305 input, including 17,536 cached; 319 output | about 13 s | Correct and concise; retained the constraint and key. |
| Codex | Fresh plus handoff | 57,639 input, including 52,608 cached; 1,130 output | about 42 s | Correct and detailed; retained the constraint and key. |

One preliminary Claude run hit its budget rail and still returned a session id,
matching the wrapper's deliberate rail-stop continuation contract.

This is not a model benchmark. It establishes three narrower facts:

1. explicit resume preserves useful working context and can improve fidelity;
2. a compact durable handoff can recover the task correctly without the native
   session;
3. resume is not universally cheaper. The provider, transcript shape, cache,
   and output behavior matter, so Custode must record outcomes rather than
   assume an economic rule.

## Implementation boundary

#651 adds host-seeded named arcs to both Oban agent wrappers. The wrappers own
in-process arc routing, provider command translation, typed resume failure,
fork capability, and telemetry. They do not own persistence or policy.

#652 persists arcs in Custode, applies the workload defaults and compatibility
fingerprint, records every continuation decision, and exposes actual state
through the shared read model used by MCP and LiveView.

#523 remains the portable handoff path. #565 remains the durable subject
context design. #596 consumes the actual arc and continuation facts for the
current-run interface. #574 and #583 protect turn ownership and late-result
recovery before session reuse becomes more aggressive.
