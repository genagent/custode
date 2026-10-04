# Project-manager workflow

Custode is a continuing conversation for ideas, priorities, and coordination.
A project remains a configured routine, with its own direct conversation and
normal role, tools, spend rails, and action gates. No additional work board or
scheduler is required.

## Everyday use

Open **Ask custode** (`/custode`) to discuss an idea or plan work. For example:

> Compare the next useful work on project A and project B. Give me a plan;
> don't dispatch it yet.

The manager reads current project evidence and proposes owners, priorities,
next actions, and blocking decisions. When you authorize the work, it sends
bounded peer requests. Their messages and replies are inspectable from each
agent or **Agent messages** in fleet activity.

You can open a project's conversation directly at any time. For example:

> For the review you were assigned, only assess compatibility. Leave the
> implementation unchanged.

That message is durable as soon as it is accepted, including while queued.
The manager's next fresh `project_progress` read includes its full text and
message ID. A manager should refresh this evidence before coordinating again.
A read is not a lock: if an earlier request is already running, the manager
must send a correction and obtain evidence of what the owner actually did.

## What the evidence means

| Record | What it establishes |
| --- | --- |
| Project progress | Observed execution, blockers, pending input, continuity, and direct operator messages. |
| Peer message accepted | The request and delivery job are durable. |
| Delivered | The recipient's inbox note was published. |
| Acknowledged | The recipient explicitly marked receipt. |
| Correlated reply | The owner reported progress, results, or a blocker for that request. |
| Reviewed evidence | The manager evaluated the requested outcome against linked artifacts or checks. |

A successful provider turn alone does not prove the assignment succeeded.
The manager records requests, superseding constraints, result references, and
remaining work in its notebook. Provider-session continuity can help, but
project IDs, message IDs, notebook records, and evidence survive a replacement
session.

## Read boundaries

`project_progress` is available only to the authenticated human operator and
caretaker. It exposes full direct operator prompts and results for configured
projects. Other routines do not gain this read, and the manager does not gain
sibling gate approval or unrestricted sibling control. Peer messages retain
their participant-only body visibility; the manager reads its own exchanges
through `peer_list` and `peer_read`.

A fresh project read starts without a `before` cursor. Older conversation
pages retain the original row cutoff and explicitly say they are older; live
execution facts are observed at the time of each call. Page limits bound the
number of exchanges, not the size of their full text. No operator constraint
is silently shortened to a preview.

## Bounded proof

Use two disposable configured projects, one Claude and one Codex. Keep cron
and automatic queues withheld and use only read-only project work. Do not
run this exercise against active production projects or grant new approval
capabilities to make it pass.

1. Discuss a plan with the manager and verify no peer request or schedule
   change occurs before dispatch is authorized.
2. Authorize one bounded request for each project. Record stable request and
   correlation IDs, and inspect delivery separately from completion.
3. Change a constraint directly in one project conversation. Verify a fresh
   manager read includes the complete new text and exact message ID.
4. Obtain each project's correlated reply with a result or blocker and
   supporting evidence. Verify an acknowledgment alone is not reported as
   completion.
5. Restart the manager and reconstruct the plan from notebook records,
   project progress, and peer exchanges without issuing duplicate requests.
6. Keep proposals, applied roster settings, and live execution separate.
   Check that no production schedule or approval authority changed.

Automated fixtures cover state, identity, and delivery contracts. The real
provider proof is a separate bounded exercise; its result must be recorded
explicitly rather than inferred from stub turns or a green test suite.

Run the opt-in proof separately from the normal suite:

```sh
CUSTODE_RUN_LIVE_PM_PROOF=1 CUSTODE_TEST_MCP_PORT=6183 \
  CUSTODE_PROOF_CODEX_MODEL=gpt-6-sol \
  mix test scripts/pm_proof_test.exs --seed 1
```

This makes six real provider turns with disposable routines, test storage,
and automatic wakes withheld. Claude uses `sonnet`; Codex uses the explicit
model override above, or the CLI default when it is omitted. Replace the example
model with one available to your CLI account. Each turn has a
two-minute timeout. The proof does not change the user's provider defaults.
It writes receipt and correlation evidence to `/tmp/custode-pm-proof.json`
(or `CUSTODE_PM_PROOF_EVIDENCE`). It checks owner replies and acknowledgment,
then rotates the manager's conversation arc and requires the new session to
recover the exact request, reply, and constraint IDs from durable records.

On 2026-10-04 UTC, the bounded proof passed with Claude Sonnet and Codex
`gpt-6-sol`: discussion did not dispatch; both owners acknowledged and replied;
the manager observed the direct constraint change; a new native manager
session recovered all five exact correlation/evidence IDs without redispatch.
This proves the coordination path for the disposable exercise, not production
project completion or broader autonomous authority. The CLI rejected the
inherited `gpt-6.1-sol` setting during an earlier attempt; the explicit Codex
model was verified separately before the successful run.
