# 023: Explainable assurance on the routine path

Status: two bounded slices from #710 are shipped. Scoped assurance records (#794)
and retained native producer/verifier evidence (#795) advance the original
synthetic contract fixture. The first proof remains partial: an actual native
worker crash and recovery are not established. Nothing activates the frozen
kernel or gives a decision effect authority.

## Decision

Keep execution, evidence and acceptance separate. Pin one case revision, artifact
revision, attempt generation and policy digest. A decision names its evidence ids,
satisfied predicates, missing predicates and contradictions. It has no effect
authority. Delivery, presence, queue completion and an agent-authored conclusion
cannot change that decision or approve a repository operation.

A trust class is assigned by the trusted recorder that observed the event. An LLM
cannot promote its own claim by passing `host_observed` or
`independently_reproduced` in a result. Custode recording a provider's text makes
its custody host-observed; the proposition inside that text remains self-reported.
External CI is an attestation with a configured issuer and exact head. A separate
verifier's opinion and a separately reproduced deterministic check are different
predicates. Provider diversity is observed execution metadata, not a caller label.

Reject known contradicting required checks. Escalate missing evidence, stale
revisions, unresolved review disagreement or an exceeded revision-round bound.
Acceptance requires all configured predicates and the designated judge; no
percentage or vote count substitutes for them. A rejection itself cannot merge,
revert or rewrite anything. Human merge gates retain their authority.

## Existing seams and gaps

| Fact | Current source | Limit |
| --- | --- | --- |
| Actual execution | ExecutionFacts, handoff snapshots | Observation is not a case lease |
| Durable helper review | OwnerReviews (#778) | Agent-authored opinion; Claude only; hard tokens refused |
| Production receipt | SubjectDocuments (#784) | File publication, not research acceptance |
| Tool response | ContextReceipts (#785) | Server emission, not model use or native run binding |
| Stage generation | Workflow Definition/Results/Runner (#750 prerequisite) | Exact callbacks, no general safe side-effect retry |
| Repository checks/merge | Repository/Gates | Exact head must be rechecked at effect admission |
| Owner status | Interval reports | Self-authored; not independent evidence |

Use these records selectively. No general WorkItem migration or kernel intake
resumption is needed. The released GenAgent adapter conflict in #777 blocks that
chosen adapter path. The bounded native proof uses actual CLI processes instead;
it does not resolve that adapter conflict or prove general execution confinement.

## Shipped slices

1. [Scoped production records](../docs/assurance.md), #794 / PR #801,
   freeze one configured owner assignment, its input/criteria/artifact bindings,
   policy and bounded logical generations. Trusted source adapters assign
   evidence classes; stale bindings and changed source revisions remain missing.
   Read projections expose predicates and contradictions without launching work
   or admitting repository effects.
2. [Bounded native proof](../docs/native-assurance-proof.md), #795 / PR #808,
   adds an explicit default-off native launch/recorder path and retains the fixed
   clean and seeded-defect cases. Actual Claude producers write the fixture
   wrapper; cold Codex verifiers receive the pinned case and artifact in separate
   worktrees, rerun the exact deterministic check and return separately recorded
   opinions. Unknown native identity, command, exit or artifact binding cannot
   become independently reproduced evidence.

The native proof observes Claude's model and requests an explicit Codex model;
Codex's actual model and both providers' observed effort remain unknown. Its
judge is the deliberately synthetic host harness, not a human approval. The
seeded case retains a passed synthetic judge with failed check/opinion predicates
and is rejected; the clean case is accepted. Both decisions have
`effect_authority=none`. Parser reassessment adds new receipts/decisions while
preserving the original unknown receipts, decisions and native records; it makes
no provider calls and does not rewrite their history.

## First-proof acceptance accounting

| Required fact | Observed evidence | Remaining limit |
| --- | --- | --- |
| Pinned base, criteria, input and submitted artifact | Real proof retains base/artifact commits, case/policy digests and recorder bindings | Host owns fixture and Git commits; producer authorship is limited to the wrapper |
| Independent cross-provider check and opinion | Actual cold Codex verifier reruns ten fixed rows against Claude-produced wrapper; clean passes, seeded fails | A fixed fixture is not general provider-quality evidence or human acceptance |
| Duplicate delivery and stale result | Native replay returns the original launch; immutable duplicate capture and stale-generation refusal controls pass | No new effect authority or general side-effect retry contract |
| Custode restart reconstruction | Fresh BEAM OS process reassesses the retained store, persists clean accepted/seeded rejected, and a separate SQLite reader verifies unchanged native rows and original report | This is not a machine reboot or a crash during an actual native call |
| Worker crash | Synthetic executable tests kill a launch owner; its unresolved workspace reservation refuses redelivery and another request | Actual native producer/verifier crash and recovery remain unproved; terminal status is not physical settlement |

The [fresh-process reconstruction audit](https://github.com/genagent/custode/issues/795#issuecomment-5984289899)
advances the public proof's earlier SQLite store-process reopen control. It uses
the completed private proof store and zero native calls. Old unknown receipts and
decisions remain alongside the new reconstruction decisions. Escaped descendants
are not attested settled; workspace reservations never expire merely because a
native terminal was observed. No fleet was started and no gate was approved.

## Standalone fixture and remaining scope

`python3 -m unittest discover -s spikes/assurance -v` still exercises the original
contract fixture: exact revisions, synthetic reviewer separation, contradictions,
duplicate/stale refusal, SQLite restart and payload conflicts. Its fabricated
reviewer metadata stays synthetic; later native results are separate evidence.

The two-slice implementation budget is consumed. #710 and #795 remain open for
the original real worker-crash/recovery proof and any explicitly agreed narrowing
of that requirement. No additional broad runtime slice follows from this note.
A new attempt after changed instructions, criteria or artifact creates a new case
or attempt revision. Retry settlement remains the specific worker contract, not
a consequence of an accepted report. Human merge gates keep effect authority.
