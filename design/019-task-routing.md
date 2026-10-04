# 019: Deterministic task routing

Status: #575 design, 2026-10-04. No live routing changes or paid experiment.
Standing routines now support both providers; temporary and one-shot/workflow
paths still require provider-specific execution work. The frozen kernel stays
frozen. A preview is not execution admission.

## One request and decision

Proposed route_preview and route_submit call one application selector. Request:
request_id, task_id/input_revision, class (implementation/review/research/discussion),
phase, profile revision, immutable context/artifact references, capabilities,
isolation, authority reference, deadline/call/time/token/USD caps, candidate exact
provider/model/provider-specific effort triples, and optional operator pins.
A parent's pins narrow permitted choices; they never expand inherited authority,
repository scope, tools or recursive delegation. Profiles retain their instructions.

Decision: selected/deferred/unsupported, decision_id, policy_version, input/profile
revision, frozen selected triple, effective limits, explainable reasons, rejected
alternatives and the timestamp/source/freshness of every capacity observation.
Record missing evidence. Native usage units and effort names are not equal across
providers. Pin requested aliases, recording resolved version only when observed.

Submit revalidates current authority/capacity/configuration inside existing
admission before enqueue; stale preview is refused or recomputed as a new decision.
UI, manager, authorized parent, CLI and external MCP share that operation and
ToolPolicy. No host gets a grant because its route was selected.

## Selection

1. Respect operator pins; an unsupported/conflicting pin returns a reason.
2. Filter required tools, context, isolation, supported triple, authority and
   admission limits. Reject host policy conflicts regardless of spare quota.
3. Apply a small versioned class/phase quality-floor table. Unknown tasks retain
   the configured conservative specialist route or defer; do not pick cheapest.
4. Select comparable eligible routes using weighted estimated work versus known
   available/reserved capacity, reset horizon and interactive reservation. Use
   measured class costs where available; stable route-id tie-breaks make replay
   deterministic. Unknown/stale pressure is not free capacity. With no fresh
   evidence, preserve an eligible configured route within conservative limits or
   defer if its admission cannot be established.
5. Freeze route at admitted execution. Fallback requires a new recorded decision
   at a safe, settled boundary. Never launch another writer after ambiguous writes.
   Cross-provider continuation uses portable context, not another provider's id.

Scheduled work continues to respect existing deferral rules. Operator messages
and manual beats retain their present distinct authority/admission behavior;
a route preview cannot override either or promise an immediate launch.

## Decision examples

| Input | Expected decision/reason |
|---|---|
| Supported explicit Claude pin | Keep pin after all hard checks |
| Codex pin with unsupported effort | Unsupported; no substitution |
| Pinned route conflicts with required sandbox | Unsupported isolation |
| More available route lacks a required MCP tool | Reject that route before pressure ranking |
| Cheap route below implementation quality floor | Reject floor; retain eligible specialist |
| Unknown task with eligible configured route | Conservative configured route |
| Unknown task and no admissible conservative route | Defer with missing capability/capacity |
| Equal fresh eligible candidates | Weighted work selection, stable tie |
| One candidate has unknown usage | Never rank unknown as zero pressure |
| Both exhausted with reset observations | Defer until an observed reset/check |
| Available provider has managed-policy rejection | Reject despite apparent quota |
| Completed preview followed by changed grant | Submit refuses/recomputes; preview grants nothing |
| Ambiguous write failure | No automatic second executor |
| Cross-family review | New portable-context execution, distinct decision |

## Evidence and experiment

Do not use Advisors.Model as routing or training evidence. Its historical feed
counts are labeled with today's routine model and missing Sonnet peers produce
1.0e9, yielding misleading n/a downgrades. Retire that evidence until corrected
exact per-turn attribution and missing-baseline refusal are tested. Yield is
activity, not quality, even after attribution is corrected.

Keep accepted/rejected outcome, correction/rework, evidence validity, latency,
provider-native usage and total repair consumption per task. Separate policy,
infrastructure, provider and reasoning failures. Use class-specific rubrics;
gates/tool success are not generic quality scores.

First preview implementation records 20 natural shadow decisions without changing
execution. A later authorized experiment uses 12 frozen read-only cases (including
clean cases), identical context/output, one Claude and one Codex route, maximum
24 primary calls plus 4 explicitly recorded repair calls, 90 minutes, and a
precommitted operator-approved token/USD cap before launch. Missing usage stops
further calls rather than being counted free. No publishing/merging from results.
Score actionable true findings, misses, false positives, valid references,
correction time, latency and usage. Blind route identity, inspect disagreements;
reserve four separate held-out cases before promoting at most one class rule.
Twenty shadow observations and these case counts cannot validate a learned router.

One bounded follow-up combines preview/logging with removing the advisor's invalid
evidence from recommendations. No automatic learned router, all-task A/B variants,
new scheduler or grant/prompt change. The capped experiment remains an explicit
later action after instrumentation and cancellation are reliable.

Implementation follow-up: #781.

## #781 implementation

route_preview and mix custode route-preview request.json share the same selector.
Only a human or configured caretaker can preview fleet candidates. Request pins
and requirements narrow configured routine ids; they cannot add a provider route,
MCP grant or parent authority. The selector freezes exact model/effort, execution
and profile revisions, task input references, requested limits, policy and every
alternative's reasons. Decisions are durable SQLite records: an identical request
id returns the original observation, and a changed payload conflicts. decision_id
reads that frozen record without refreshing it.

The operator-authored routing_preview_policy defines exact triple quality tiers,
relative work weights, class or class/phase floors, observation freshness and an
interactive reserve fraction. These are declared conservative heuristics, not
learned quality or measured class costs. Unknown exact triples are unsupported.
The built-in policy includes explicit Claude specialist/review routes only;
operators can add reviewed Codex triples without treating provider effort names
as interchangeable. A required capability must be declared in that policy, and
required tools must also occur in the routine's captured argument contract.
Claude's current local execution is not represented as a read-only sandbox;
Codex's actual sweep read_only contract is distinct. Native context references
can restrict a request to their provider; portable references do not transfer a
provider session id.

Pressure uses the most constraining observed provider window. Available fraction
minus configured interactive reserve, divided by the route's work weight, gives
the rank; exact route id breaks ties. This is a subscription-pressure heuristic,
not a live reserved-capacity allocator. Unknown/stale/future timestamps and
partially unknown windows cannot win as zero usage. Provider rejection and daily
rails reject a candidate despite spare-looking quota. Unknown task classes retain
only an eligible configured specialist or defer. Effective limits are a proposed
bounded envelope, not a changed running configuration. A subsequent execution
operation must revalidate configuration, authority and admission independently.

Model advisor jobs now emit no recommendations. Historical model suggestions
remain in Feed but are hidden from the standing recommendation projection; the
default schedule is disabled. No correction of model-attribution or meaningful
quality measurement is claimed. Existing configured models remain unchanged.

Fixtures prove deterministic selection, constraints and durable replay; they are
not counted as the 20 natural shadow requests required before a separately
authorized promotion/evaluation. No provider call or automatic fallback is made.

Operating note: pull, migrate and restart for the decision table and retired
advisor. The default runtime, scheduling, grants and live routes are unchanged.
