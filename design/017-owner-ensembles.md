# 017: Bounded owner reviews

Status: design/proof for #772, 2026-10-04. Go for a narrow independent-review
contract; no-go for running GenAgent ensembles in the live fleet without a durable
host adapter. Standing-runtime migration #752 is not a prerequisite for designing
or implementing a coordinator over existing durable jobs.

## First use

A repository owner asks two read-only reviewers to assess a specific immutable
PR diff and test evidence. Each returns findings or a clear clean result with
references. The owner evaluates disagreements and writes one synthesis. Helper
success, vote counts and reported verification never approve a gate or merge.
No automatic fan-out on every heartbeat and no recursive helper hierarchy.

## Existing and released surfaces

start_agent creates a parent-owned temporary multi-turn Claude worker with its
workspace, model and session record. Its existing memory MCP scope and #639
restriction on recursive delegation remain. run_job is a bounded Claude
OneShotJob returning a parent inbox/feed result; artifact paths are not verified
durable subject documents and inbox pruning is not an output retention policy.
Workflow.Runner owns staged durable Claude jobs. None of these is an implicit
mixed-provider pool or aggregate-budget reservation.

Released gen_agent_ensemble 0.6.1 includes Pool, Solo, Pipeline, Supervisor,
Switchboard, Debate and Consensus. Pool uses a fixed worker backend template;
mixed-provider routes require explicit cohorts or an appropriate heterogeneous
strategy. Its tell_with_completion, poll/await and cancel APIs are usable, but
results and tokens are in memory. A replaced worker starts fresh native context.
Cancel may return cancelled_unconfirmed and proves no subprocess settlement.

The six fixture tests in spikes/gen_agent_compatibility include two held parallel
reviews, one successful and one failing, duplicate actual completion envelopes,
and cancellation followed by actual late envelopes. Results stay distinct and
terminal tokens are not reopened. No paid provider, sandbox, grant, durable job
recovery or external-process termination was tested.

## Shared request and result contract

A future owner_review operation and MCP tool use one application operation.
Request fields: owner id; immutable brief/evidence references; parent execution
identity; two child roles with explicit provider/model/effort or a recorded route;
existing authority reference; deadline; aggregate call, token and dollar caps;
and a request id. Maximum two children in the first slice. Preview explains
eligibility; submit revalidates and atomically records parent plus child jobs.
Child admission reserves remaining aggregate capacity through existing Oban and
rails. No independent scheduler or inherited unbounded launch permission.

Persist owner/run/child associations, frozen inputs/route/grant revision, per-child
attempt and receipt, accepted result and usage. Duplicate submission returns the
same run. Completion identity includes generation, logical attempt and provider;
late events remain evidence without replacing the accepted result. Result fields:
all/partial/cancelled, each child's actual route/status/findings/references,
known usage or explicit unknown, settlement state, and an owner synthesis link.
Failure does not fabricate a clean review. Timeout returns partial evidence;
retry of a side-effecting helper is never automatic.

Cancellation stops admission of new children, requests cancellation of active
children and reports each child's settlement separately. It does not erase prior
results or imply OS settlement. Parent pause/rail stops further admission. A
helper cannot widen tools, repository scope, approval classes or delegation.
ToolPolicy and the maintained MCP reference must ship with the new tool.

Native provider helpers may supply authored evidence to the same owner summary.
Do not invent individual native helper ids, usage totals or cancellation support
when the host does not expose them. Mark those limits in the result.

## Implementation choice

Start with a durable coordinator over bounded one-shot jobs. Reuse parent inbox,
Feed, admission, rails and cancellation facts; add durable child/result retention
and cross-provider one-shot execution as necessary. A GenAgent ensemble can later
sit inside that boundary if exact options/checkpoint/settlement parity is proved.
An in-memory Pool alone would bypass the durability we need.

File one bounded implementation slice for two explicit read-only routes, durable
association, aggregate admission, partial results and cancellation. Do not adopt
the entire ensemble catalog. Owner interval reports summarize outcome and
unresolved questions, not every helper event. #596 owns the navigation to inspect
children; #575 owns route selection. No current authority or runtime changes.

Implementation follow-up: #778; runtime proof adapter: #777.

## First implementation slice (#778)

The opt-in owner_review operation retains exact supplied evidence, its digest,
observed parent execution (active may be absent), owner configuration revision,
two explicit Claude routes, two Oban jobs and independently fenced results.
Both jobs are inserted with the parent record in one SQLite transaction. Owner
scope is rechecked for each operation, and child start checks the captured owner
revision, current pause/rails and shared deadline. Reading never reruns a job.
Results and missing completion receipts survive restarts. Every accepted callback
records one durable feed event; findings remain agent-authored, not approval.

Native query arguments disable all built-in tools with `--tools ""`, use an
empty strict MCP inventory, seal user/project/local settings, disable hooks and
slash commands, and exclude dynamic prompt sections. They do not force `--bare`
API billing. This is a constrained native CLI contract, not an independent OS
sandbox or a claim that hidden provider context was measured. Real option
conversion is covered by fixtures; paid native client conformance is outstanding.

Limits count two native invocations, not individual provider API requests. Each
invocation has one native turn, half the requested native USD stop and the
remaining shared deadline. USD stops are not a hard billing guarantee. Review
reservations are serialized for this operation and conservatively held for 24h
at at least their cap, including missing usage and cancellation. Other fleet
surfaces retain their existing rails; no global concurrency quota is claimed.
The hard token limit and cross-provider parity are unavailable and explicitly
refused, so #778 remains open for those guarantees. Native failures and crashes
never fabricate clean reviews or zero usage. Cancel requests Oban cancellation;
a returned query and Oban state do not attest OS settlement. A duplicate job
cannot relaunch or replace an already running or terminal review. No automatic
retry, recurring fan-out, synthesis by vote or recursive helper delegation.

## Admission and receipt follow-up (#778)

The coordinator reuses the owner_reviews record and existing Oban jobs; there is
no new table or scheduler. Submission and child admission serialize with routine
configuration handoff, then check current owner scope, configuration, pause,
rails and limits in an immediate database transaction. The retained authority
includes the submitting actor, owner snapshot, observed gate and gate mode,
owner limits and fixed query policy/package revision. The gate observation binds
the request; it grants the children no effect authority. Each child is bound to
all stored launch arguments and the captured authority and query-policy digests.
Timeout is the remaining shared deadline. Native identity remains unknown.

Accepted terminal results and known usage are retained once. Up to eight delivery
metadata observations and the first valid late authored result remain separately
inspectable, without replacing an accepted result or booking usage twice.
Explicit reconciliation persists a missing terminal receipt as unconfirmed and
never relaunches it. Ordinary inspection remains inert. The projection carries
an owner conversation link and child inspection references. Legacy queued records
without the stronger contract remain inspectable but cannot acquire launch
authority retroactively.

Nonpaid fixtures cover independent parallel clean/findings, partial failure,
concurrent aggregate reservation refusal, changed options/authority/limits,
duplicate noise, cancellation and missing-receipt reconciliation. Copied actual
records and Oban jobs survive a SQLite repository process reopen. This is bounded
store-process evidence, not a full VM crash or native descendant recovery proof.
Focused seeds are 1, 12345 and 777; all five repository gates precede every push.

Cross-provider execution remains blocked on exact native option and rail parity.
Released ObanCodex 0.7.0/CodexWrapper 0.6.0 expose no native USD stop or matching
single-turn cap, and tool-free native profile conformance is unproved. A Codex
request returns versioned provider_parity_unavailable findings before insertion;
it cannot silently weaken this operation's required limits. Hard total-token
caps remain unavailable for both providers and are refused. #778 therefore stays
open. Paid native conformance, full VM recovery, all-descendant settlement and a
global concurrent fleet quota are also unproved. No paid models, GenAgent pool,
automatic fan-out, approval, merge or runtime adoption is included.
