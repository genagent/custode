# 018: Current run, input and helpers

Status: #596 design and current-contract audit, 2026-10-04. Reuse the execution
and receipt projections; no new runtime is necessary. Remaining UI composition
and durable helper result navigation are a bounded follow-up, not shipped here.

## Facts and their meaning

| Fact | Authority | Display rule |
|---|---|---|
| Desired provider/model/effort/location | Current Routine and revision | Label next desired execution, never a running turn |
| Applied lifecycle contract | Sole live provider and applied revision | Infer configuration fields only on exact revision match; otherwise unknown |
| Actual turn | Captured Oban job plus correlated live continuation | Show provider/job/attempt/generation/turn and captured execution options |
| Native session | Exact correlated observation | Continuity handle, not completion or permission to run |
| Input | OperatorMessages durable receipt | Show acceptance/delivery/lifecycle independently |
| Helper | Parent-owned spawn/job plus accepted result | Viewing does not resume, accept or restart it |
| Plan | Identified document revision | Current authored plan, not routine prompt, gate or process state |

ExecutionFacts reads the process before querying durable turns so the named job
is included. ProjectProgress combines execution, continuity, wake, attention and
conversation with independent read times. Its conversation cursor freezes row
membership, not live results; an older page is not a coherent current snapshot.
Unknown effort/usage/liveness stays unknown. Aliases are captured requested model
names unless the provider supplies resolved-model evidence.

## Input acknowledgment and ordering

Accepted means a durable receipt exists. queued means it has not been admitted.
An admitting claim separates provider submission from replay eligibility;
delivered means the provider accepted it, not that reasoning completed. The
lifecycle may be executing, waiting_for_input, waiting_for_approval, completed,
failed or refused. Public message identity stays distinct from correlation:
a question's answer is another submission within the same interaction.

Retry an ambiguous transport using the same caller/target/idempotency key and
text. Changed text with that key conflicts. Reconnect discovers the original id
with list_operator_messages and awaits that exact receipt. Do not submit a new
key because the textbox or socket looks idle. Ordered admission claims only the
oldest queued input; a continuation's completion cannot finish the next row.

A future count must query all undelivered rows, not count a paginated recent page.
Show queued and admitting separately from executing/waiting. Edit/remove remains
unsupported: it needs a revision-checked atomic claim transition. A message
already accepted by a provider cannot be recalled by deleting a database row.
No provider-specific steer behavior is promised by the shared queue.

## Pause and stop

Current Pause uses Actions.pause and the idempotent fleet.pause_agent operation.
Both providers lock the lifecycle and clear pending gate/question state. They do
not thereby establish that an executing provider job or subprocess has stopped.
ExecutionFacts retains that job under a paused process. Durable queued input is
not deleted; schedule skips while paused; child jobs are not recursively stopped.
Resume is a separate authorized action and may allow retained input to proceed.

Do not relabel Pause as Stop. A future cancel-current-turn command must return
requested/confirmed/unknown settlement per execution and explicitly state whether
it affects children, queued input and future schedule. Unknown settlement must
block a competing writer. Unsupported controls show a concrete reason and never
fall back to a fresh execution. A viewer cannot cancel somebody else's helper.

## Compact surface

Keep actual turn and input strip above the conversation, with desired changes
in a separately labeled detail. Link helper brief/state/result and return to
owner. Keep full operational view accessible. A current plan link includes its
revision and producer; reopening it does not rerun a producer. Owner reports
summarize useful outcomes, not raw helper events.

The proposed custode.current_run.v1 projection composes the facts above with
observed_at/source, exact message ids, queued/admitting counts, helper links and
plan reference. UI, caretaker, CLI and external MCP use one authorized application
read. Existing agent_status/project_progress and receipt tools remain available;
this note does not add a tool or claim current full helper/result parity.

## Exercised evidence and limits

Existing fixtures cover changed desired configuration versus captured execution,
early session/stale identity, paused physical work, concurrent duplicate input,
ordered queue admission, waiting continuation, terminal failure, boot recovery,
new constraints on a fresh read and denied project readers. SubAgents fixtures
cover completion checkpoint and orphan notices; they do not provide durable
helper-result history after forgetting the spawn record. The GenAgent proof
covers child coordinator cancellation only, not subprocess cancellation.

Run execution_facts_test, operator_messages_test, project_progress_test,
project_progress_tools_test, agent_handoff_test and sub_agents_test under seeds
1, 12345 and 777. These are fixture exercises, not natural live-fleet proof.
Current-run composition and helper result retention belong to one follow-up;
explicit physical cancellation remains subject to the existing reliability
contract rather than an invented Stop button. No prompt, grant or runtime change.

Implementation follow-up: #780.

## Implemented current-run projection

#780 adds `current_run`, `mix custode current-run ID --json`, and one shared
compact renderer in both operator views. ProjectProgress embeds the same
projection. Observations are labeled independent; no composite atomic snapshot
is claimed. Pending direct-operator counts cover the full set, with the oldest
20 exact receipt references. Private delegated input remains outside that set.

Helper spawn/removal navigation is retained in helper_records independently of
SubAgents' active ownership registry. Results use the original durable receipt,
including later accepted completion; removed helpers never regain control
authority. Reusing an id creates a separate record. Receipt bodies remain
restricted to the original parent or human; other caretakers see metadata and
restricted result availability. Initial helper turns retain bounded authored
feed evidence subject to normal feed retention. Native process settlement
remains unknown. Plan reference/revision remains explicitly unavailable until
a document is identified; the roster prompt and approval gate are not plans.

The fixtures cover a queue larger than a page, admitting versus executing and
waiting, view reload, helper cleanup, late receipt completion, helper id reuse,
reader denial and MCP/project projection parity. Existing ExecutionFacts
fixtures continue to exercise changed defaults and stale execution identity.
These are controlled tests, not live-fleet delivery proof.
