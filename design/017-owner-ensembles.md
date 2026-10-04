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
