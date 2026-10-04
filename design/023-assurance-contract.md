# 023: Explainable assurance on the routine path

Status: decision spike for #710, 2026-10-04. The proof is a standalone contract
fixture, not an activation of the frozen kernel or a real provider-quality result.

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
resumption is needed. No new transport or database is required. The released
GenAgent adapter conflict in #777 blocks that chosen adapter path, but does not
make raw CLI review impossible; the first native proof is still outstanding.

## Standalone proof and its limits

`python3 -m unittest discover -s spikes/assurance -v` exercises pinned case/policy
and artifact revisions, clean/seeded-defect fixture outcomes, refused stale
attempts, actor/provider separation, contradictory reviews, untrusted issuers,
duplicate submission, SQLite restart and payload conflicts. Fixture reviewer
metadata is synthetic and deliberately labelled. The clean fixture demonstrates
the evaluator contract, not that a real Claude/Codex panel correctly reviewed it.
With the real review missing, the same policy escalates.

SQLite first-writer and replay facts are tested here; physical process settlement,
worktree isolation and a native verifier rerunning pinned checks are not. Do not
wire this proof evaluator into authority or describe its synthetic ids as trusted
production evidence. The real first proof from #710 remains open.

## Two bounded implementation slices

1. Add an opt-in assurance record for one configured owner assignment, referencing
   the existing review, execution, document and repository facts. Freeze case and
   output digests, recorder-issued evidence classes, policy and bounded rounds;
   expose explainable read projection only. Missing issuer/run/revision binding
   remains missing. No automatic effect or generic task board.
2. Run the actual seeded-defect and clean repository cases in isolated worktrees
   through Claude and Codex, including independent rerun, restart, duplicate and
   stale-result cases. Retain exact command/results and decisions. Prove current
   acceptance independently of effect admission before considering automation.

A new attempt after changed instructions, criteria or artifact creates a new case
or attempt revision. It never quietly reclassifies old evidence. Retry settlement
remains the specific workflow contract, not a consequence of an accepted report.
