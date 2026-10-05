# A small missions convention over existing records

The decision for #459 remains the routine path from design/026. The bounded API
fixture tests a convention before introducing a mission schema or executor.
It does not establish that a manager and two native workers beat one routine
working a labelled backlog.

## Pinned objective

Inventory a capability's `name` and `schema`, then check the inventory against the
same artifact. A direct operator change additionally requires `caller` as a
separate field, retaining read-only authority. The checker cannot report the
second step before receiving the producer's pinned artifact. No repository write,
new tool permission, gate approval or cancellation authority follows.

Both fixture variants retain the same final criteria and constraint:

- Criteria: `Inventory fields name/schema/caller; check all three against the same pinned artifact.`
- Constraint: `Include caller scope as a separate field; retain the same read-only authority.`
- Host fixture artifact label: `fixture-inventory-v2`.
- SHA-256 of the literal fixture bytes `fixture inventory with caller scope`:
  `43e8f0ac057ecf612ada3e8488f63f9d4598dbed14c22ade0cda6984662a8afb`.

This is host-authored fixture content, not a native-produced file or Git commit.
The one-routine variant is the record analogue of a labelled backlog: two ordered
Notebook todos reference one current Memory objective record. The peer variant
uses a caretaker and two configured owners, with Claude/Codex configuration
metadata but no provider execution.

## Record convention

1. Before dispatch, save the objective ID, current criteria, assignment request's
   exact body and stable retry key in the coordinator's Memory record. Append
   important scope changes to its Notebook journal. Memory is a current upsert;
   the journal supplies separately retained history.
2. Send the bounded request with `PeerMessages.send`. Link its actual returned ID
   and correlation root into the current record. The send and notebook/memory
   update are separate transactions.
3. If the coordinator loses its process after send but before linking the ID,
   reconstruct the exact saved request and retry its stable key. The actual peer
   API returns the original committed envelope. Do not invent a new key because
   its result was not recorded locally. A changed body under the old key is an
   idempotency conflict.
4. Read fresh `ProjectProgress` before applying a direct operator change. Retain
   the original operator message ID and full constraint. A new FYI/request uses a
   new key, explicitly names the superseded request and leaves the original
   immutable. That record does not prove old work stopped or obeyed new scope.
5. A checker may report its dependency blocked. When the producer reports a pinned
   artifact, the coordinator can reply to that received blocked message with the
   artifact and operator message ID. `PeerMessages.reply` preserves the checker's
   correlation root; the coordinator cannot reply to its own outgoing request.
6. Reconstruct the current objective and correlated exchange with a fresh reader.
   Keep reported and accepted distinct. Peer receipt/delivery and TODO completion
   are their own bookkeeping, not independent verification or approval.

These are agent conventions, not enforced mission transitions. The test manually
chooses its payloads and evaluations. Actual server APIs enforce sender/recipient,
retry identity, message immutability and correlation. They do not judge whether
an artifact satisfies the objective or whether the constraint was obeyed.

## What the API fixture establishes

`test/custode/missions_protocol_contract_test.exs` uses the shipped Memory,
Notebook, PeerMessages, OperatorMessages and ProjectProgress APIs. Its short
coordinator fixture process exits after committing a send; a new reader recovers
from records without another peer envelope. This is not a native caretaker crash
or full application restart.

OperatorMessages uses a deliberately queued nonpaid delivery callback. Executable
queues and the scheduler are disabled, and peer owners ignore inbox wakes. Peer
mail remains pending; the fixture reads its accepted records and never invokes a
provider. Recipient-side reads retrieve the revised operator constraint and the
checker's exact artifact/operator-message binding. Unrelated peers cannot read
that exchange. Cleanup deletes only this fixture's own records and jobs.

| Retained bookkeeping in this fixture | One routine | Caretaker and two peers |
| --- | ---: | ---: |
| Current objective Memory records | 1 | 1 |
| Ordered Notebook todos | 2 | 0 |
| Notebook journal entries | 0 | 2 |
| Direct operator message records | 1 | 1 |
| Peer envelopes | 0 | 7 |
| New envelope from exact retry after send-gap loss | 0 | 0 |

Counts describe constructed record overhead, not equivalent completed work,
coordination turns, model consumption or delivery benefit. The peer variant adds
independent ownership/correlation at extra record cost; independence of a
native check remains unobserved. Neither variant establishes real acceptance.

## Limits and next decision

A single Memory upsert has no compare-and-swap or mission version enforcement.
One coordinator must reconcile before writing; concurrent coordinators and
compacted/retired journal history remain limits. Recovery needs the exact saved
body/key; a lost intent or changed payload cannot safely be reconstructed by
retry. Peer reads are bounded and paged, so a missing result on one page does not
establish no request exists. Fresh operator reads are observations, not locks.
Unknown physical execution settlement stays unknown.

Retain the current path. No observed fixture failure requires a new mission
engine. #459 remains open for a real comparable objective, actual native delivery,
operator constraint changes, blocked assignment and coordinator recovery, with
accepted delivery, elapsed time, spend, corrections and duplicate work recorded.
Agree on the improvement before that run. The test supplies none of those benefit
measurements and does not resume the frozen kernel or #554/#555 decisions.
