# 006: Repo stewardship -- the worker that creates the backlog

Status: draft, design only. Prompted by redisctl becoming an official
product: "not just working the backlog, but creating a backlog. run
tests, check coverage, check docs. sweep the steps, clean the windows,
maybe fix a door knob, take out the trash, on a constant basis."

## The gap

Every repo routine today is a `backlog_worker`: it drains a board
someone else filled. Nothing in the fleet *fills* boards continuously.
Design/005's backlog-sweep workflow fills one episodically -- an
exhaustive, expensive dig you run on demand. Between digs, drift
accumulates silently: a doc example goes stale, coverage erodes, a dep
grows a CVE, unreleased commits pile up on main, a test gets flaky.
None of that is on the board, so no worker ever picks it up.

The gap is a second role, not new machinery. Call it the **steward**.
A steward is to one repository what the caretaker is to the fleet:
it watches condition rather than tasks, and its output is mostly
*board entries*, not code.

## What a steward sweep is

Two halves, in one turn:

**1. The battery.** Run the ecosystem's standard health checks in the
checkout, with real exit codes:

- `Cargo.toml` detected: `cargo fmt --check`, `cargo clippy -- -D
  warnings`, `cargo test`, `cargo audit`, `cargo outdated`, doc build,
  coverage if configured
- `mix.exs` detected: `mix format --check-formatted`, `mix compile
  --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix
  hex.audit`, `mix docs --warnings-as-errors`, `mix dialyzer`

Detection over configuration (position: no hand-config). A repo can
override or extend the battery in its roster entry later; day one, the
convention set is the battery.

**2. The judgment pass.** One bounded look at the battery results plus
the recent activity window (commits since last sweep, open PR ages,
release distance): what changed, what is drifting, what deserves a
board entry. This maps onto design/004's two advisor grades exactly --
the battery is `:deterministic`, the assessment is `:judgment`, and a
steward turn is one of each.

## Findings become the board

The "creating a backlog" half. Each finding the judgment pass keeps
becomes a GitHub issue: conventional title, an `upkeep` label, the
evidence inline (the failing command and its tail, the coverage delta,
the CVE id). Two disciplines carry over from the advisor work:

- **Seen-set with cooldown.** A finding is keyed (check + subject) and
  remembered in the routine's memory; it refiles only when the
  underlying fact changes, never on every sweep. No board spam.
- **Dedup against the live board.** Filing checks open issues first;
  a finding that is already filed gets at most a comment when it
  worsens.

The flywheel this completes: the steward files, the backlog worker
drains, the reviewer reviews, the advisors tune cadence and budget,
the rails cap the whole loop. Filing is a write, so it rides an
approval gate like every write -- one gate per sweep covering the
batch of drafted issues, individually droppable.

## The doorknob rule

Some findings are beneath the board: a dead link, a stale badge, a
typo'd doc example, a missing `#[must_use]`. For these the steward may
propose ONE small fix PR per sweep -- same verbs, same draft-PR-first
flow, same gate, same one-item-per-sweep discipline the backlog worker
lives by. Anything that needs judgment beyond mechanical, or touches
more than a screenful, becomes an issue instead. The steward never
fixes what it files.

## Steward and the deep dig (design/005)

Complementary cadences over the same intent:

- **Workflow backlog-sweep**: episodic, exhaustive, expensive. Run it
  when a repo joins the fleet or after a long drift (it reads
  everything and rebuilds the board).
- **Steward**: continuous, incremental, cheap. Keeps the board honest
  between digs, one sweep at a time.

They meet in one place: a steward that keeps finding systemic drift
(many findings across many sweeps, or a whole subsystem it cannot
assess incrementally) suggests a deep dig through the same
suggestion-gate grammar design/005 defines. The steward is also the
natural author of the "backlog is dry" signal the cadence advisor and
the 005 suggestion path both want.

## Fleet shape: pairing, not merging

For a repo that gets both roles, they stay two routines -- a worker
and a steward -- rather than one routine with two jobs:

- Different cadences (backlog */30 in a window; stewardship @daily or
  @weekly), different budgets (stewardship is mostly battery + one
  bounded judgment call; it should be cheap), different prompts.
- Addressability (position 1): "prompt the steward about coverage"
  and "prompt the worker about issue #12" are different phone numbers.
- Position 5 stays intact: the steward's writes are issues (no
  contention) plus at most one doorknob PR per sweep; the worker's
  one-gated-item flow is untouched. Two agents, still sequential
  per-repo work, because they run on the same queues under the same
  rails.

The tempting alternative -- teach the backlog worker to do health work
when the board is dry -- is rejected as a role blur: the sweep prompt
grows a second job, spend becomes unattributable, and "who found this
vs who fixed this" disappears. Idle workers are fine; the cadence
advisor already handles chronically idle ones.

Rollout matches the ask ("id kind of want this for all my repos"):
the steward is a profile, so adding one is a roster write-back away
(form, conversation, or file -- the design/001 paths). Start with one:
redisctl, the repo that just became a product and has the strongest
care-and-feeding case. Let the profile prove itself there before the
fleet-wide rollout; every further add is one gate.

## The profile (sketch)

```elixir
steward: %{
  cron: "@daily",
  prompt: "Do your stewardship sweep now.",
  role: :steward,
  mcp: true,
  model: "sonnet",
  effort: "low",
  max_budget_usd: 5.0,
  daily_budget_usd: 10.0,
  timeout_ms: 900_000,       # the battery runs real suites
  max_turns: 40,
  tags: [:repo, :upkeep],
  sensors: [:ci]
}
```

The role prompt carries the battery-by-detection, the seen-set and
dedup disciplines, the doorknob rule, the filing format (conventional
titles, `upkeep` label, evidence inline), and the #196 orders (no
background watchers at turn end; synchronous checks with exit codes).

## Tiles: a phone number on one page, a subject on the other

The steward raises "is this a new tile?" The answer differs by page,
and both answers are already implied by existing decisions:

- **Fleet page: a tile is a phone number** (position 1). The steward
  is a different phone number from the worker -- different cadence,
  budget, gate stream, memory -- so it gets its own tile. Merging the
  pair into one tile would re-blur what this design refuses to merge:
  whose gate is "needs approval", whose spend is the number.
- **Repositories page (#193): a tile is the subject.** Worker and
  steward share the repo tile there, because that page asks "how is
  this repo doing", not "who is working". The steward's health chip
  lives on that tile.

The pressure the steward actually creates is fleet-page soup as repos
gain pairs. The answer is grouping, not merging: a repo's agents sit
adjacent under a small repo header (the sessions-under-projects move,
and the meta rail's "a place, not a slot" instinct), with the steward
tile visually quieter than the worker's -- it is @daily and mostly
green. Sorting stays activity-based across groups; inside a group the
pair stays together.

Non-repo routines (quakes, italian, stars) are one-to-one subject and
agent, so the distinction collapses and nothing changes for them.
"Tile = subject" and "tile = agent" only diverge when a subject has
multiple agents, which today means exactly the repos -- which is what
the repositories page is for.

## Later: the zero-token battery

Slice-two economics: the battery does not need an LLM at all. Custode
could run it outside the turn (plain command execution, exit codes and
tails captured) and hand the results to the judgment pass in the
prompt -- the design/004 Digest pattern applied per-repo. That cuts
the steward's cost to one bounded judgment call per sweep and gives
the dashboard a machine-readable health row per repo (which the
repositories page, #193, would render as a health chip on each tile).
Not day one: it puts repo-command execution into custode core, which
wants its own gate story (the roster declares the battery; adding or
changing it is a gated write). Day one, the agent runs the battery
itself inside its turn -- zero new machinery.

## Non-goals

- **No autonomous fixing beyond the doorknob rule.** The steward is a
  groundskeeper, not a renovator; big findings go to the board.
- **No bespoke health store.** Findings live on GitHub; trends the
  dashboard wants come from the ledger/feed and, later, the Digest.
- **No merged worker+steward role.** Two phone numbers.
- **No fleet-wide rollout before redisctl proves the profile.**

## Slices

1. `:steward` role prompt + profile; redisctl gets one via the normal
   roster path. Agent runs the battery in-turn. Filing gate live.
2. Seen-set/cooldown memory discipline verified over a week of sweeps
   (no board spam, no re-files); tune the judgment prompt.
3. The doorknob rule enabled (one small PR per sweep).
4. Roll out to the rest of the fleet's repos, one gate each.
5. Zero-token battery + per-repo health row + #193 health chips.
6. The systemic-drift suggestion (steward proposes a design/005 deep
   dig through the suggestion gate).

## Relationships

- design/004 supplies the deterministic/judgment split and, later,
  the Digest the zero-token battery feeds.
- design/005 is the episodic sibling; the steward suggests digs and
  shares the "board is dry" signal with its suggestion path.
- #193 (repositories page) is where per-repo health becomes visible.
- #196's orders (no orphaned watchers, synchronous checks) are
  baked into the steward role prompt from birth.
- #39 (growth inventory) must cover steward memory and any health
  rows.
