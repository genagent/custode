# 005: Workflows -- the deep dig as a first-class, Oban-native run

Status: draft, design only. Nothing here is scheduled.

## The itch

The fleet is built for steady drainage: one routine, one repo, one gated
item per sweep, all day and all night. What it has no shape for is the
occasional *deep dig* -- the deliberately expensive, many-agent
investigation that Claude Code's Workflow tool does so well: sweep every
source a project has (spec, docs, code, closed issues, adversarial gaps),
merge and dedup, adversarially verify, and emerge with a drafted backlog
or a standalone research report. It is a token burner by design, and it
is the single best way to fill the board the routines then spend weeks
draining.

Today that lives only in an interactive Claude Code session. The ask:
custode should be able to run one -- from a button, or from a suggestion
an agent makes -- with the fleet's own guardrails around it.

## Position check (design/000 and the settled positions)

**Sequential by design.** Position: parallel work within a repo is not
planned; throughput comes from 24/7 operation. A workflow looks like a
violation -- it is a fan-out diagram. The reconciliation is that the two
things a workflow diagram conflates are separable in Oban:

- the **DAG** says what depends on what (miner results feed the merge;
  the merge feeds verification);
- the **queue** says how many run at once.

An Oban-native workflow runs its whole DAG on a `:workflows` queue with
concurrency 1 and is exactly as sequential as everything else in the
fleet: same token cost, longer wall-clock, zero contention. Wall-clock
is the thing the fleet has already decided it does not care about.
Concurrency becomes a queue knob that can be raised per-machine later,
not a structural commitment. Note also that the conflict cascade that
settled position 5 was about *writes* (parallel PRs colliding); workflow
nodes are readers and drafters -- the only writes (filing issues, saving
a report) happen after the run, through a gate, sequentially.

**No hand-configuration.** Users do not author orchestration scripts.
Workflows ship as a small named catalog with data definitions; launching
one is a click or a sentence.

**Borrow the world.** The backlog a sweep produces lands as GitHub
issues via `gh`, matching the repo's templates and labels -- not in a
bespoke store. The board stays GitHub; the workflow is just a very
thorough way of writing to it.

**Generalize on two instances.** The coordinator shape below (a process
that enqueues jobs and advances on their completion) already exists once,
as `ObanClaude.Agent`. The workflow runner is the second instance. The
design deliberately does NOT merge them yet -- an agent is a stateful
session threading one conversation; a workflow node is a one-shot run --
but the return path (`job_finished`-style) should be recognizably the
same seam, and if a third instance appears, that is the generalization
moment.

## Why data, not scripts

Claude Code's workflows are JavaScript because an interactive session
wants arbitrary control flow, and it pays for that with a deterministic
replay machinery (no `Date.now()`, journaled agent results, cached
prefix resume). Custode does not need any of that, because Oban rows are
already the journal:

- a node = one Oban job; its structured result is persisted when it
  completes;
- resume-after-restart = enqueue only the nodes without persisted
  results (the transactional claim and retry semantics come free);
- the "edit and re-run only what changed" trick falls out of keying
  node results by `{workflow_run, node_name, args_hash}`.

So a custode workflow is a data structure, not a program:

```elixir
%Workflow{
  name: "backlog-sweep",
  stages: [
    %Stage{name: :mine, nodes: [:spec, :docs, :code, :issues, :gaps]},
    %Stage{name: :merge, nodes: [:merge], effort: :high},
    %Stage{name: :verify, per_item: true},   # one node per merged item
    %Stage{name: :draft, per_item: true},
    %Stage{name: :critique, nodes: [:critic], effort: :high}
  ]
}
```

Each node carries a prompt template (rendered with the repo, upstream
digests, and roster context), a `--json-schema` for its result, and
optional model/effort overrides. Stages are barriers: a stage starts
when the previous one has all its results. With queue concurrency 1 the
pipeline-vs-barrier distinction that matters so much in Claude Code's
harness is moot here -- barriers are the simpler model and cost nothing.

Two things the Claude Code write-up teaches that carry over directly:

- **Digests, not transcripts.** Downstream prompts get truncated
  digests of upstream results, so late-stage prompts stay bounded.
- **Verify before draft.** Adversarial verification kills items before
  any drafting effort is spent, and verifiers must cite evidence to
  drop; the default verdict is keep.

And one constraint that *inverts*: Claude Code's subagents cannot run
`gh` (sandbox TLS), so inputs are pre-staged and filing happens
post-workflow. Custode's nodes can run `gh` reads directly. Filing
still happens at the end through a gate -- not because it cannot happen
earlier, but because writes are gate-mediated, always.

## Execution model

`Custode.Workflow.Runner` -- one process per run, the same
enqueue-and-advance shape as the agent layer:

1. Launch is **gate-mediated**: the gate card shows the workflow name,
   the target repo, the node count, and a spend estimate (nodes x the
   repo's observed per-run cost from the ledger). Approving arms it.
2. The runner enqueues the current stage's jobs on `:workflows`
   (concurrency 1, its own queue so a workflow never starves the
   sweeps). Each job is a normal `ObanClaude` run with a schema.
3. Results persist per node (a `workflow_node_results` table under the
   storage doctrine: records in the db, any long report artifact as a
   file in the workspace, per design/002).
4. Stage complete -> render the next stage's prompts from the digests
   -> enqueue. Run complete -> the terminal payload (draft issues, or
   a report path) is attached to a closing gate: "file these 14 issues"
   / "save this report", one approval for the batch, individual
   uncheck-before-approve if the operator wants to drop items.
5. The run has its **own budget rail**, separate from the daily agent
   rails. Hitting it pauses the run exactly like `budget_paused` on a
   routine -- resumable, never silently truncated (the no-silent-caps
   rule from the advisor work applies: a paused run says what it has
   not done).
6. Feed entries at launch, per-stage completion, and finish; the run
   renders as a stage checklist card (the Research-pattern checklist
   shape from genagent_bench is the obvious visual precedent).

Restart-into-resume comes free: the runner rehydrates from persisted
node results and enqueues only what is missing.

## The two entry points

Both converge on the same launch gate; there is no second path.

- **The button.** Lives on the repository view -- workflows are
  repo-scoped, so the repositories page (#193) is its natural home,
  with the same affordance on an agent's repo panel. Click -> pick
  from the catalog -> the launch gate opens with the estimate.
- **The suggestion.** Agents propose runs the same way they propose
  anything: the caretaker (or a future advisor) files a gate --
  "redis-tower's backlog is down to 2 open workable issues and the
  routine is idling; run backlog-sweep?" This is the advisor grammar
  from design/004 pointed at a bigger lever: the backlog-dryness
  signal is already computable from the cadence advisor's
  `backlog_size` read.

The flywheel this closes: routines drain the board; a workflow refills
it; the cadence advisor notices utilization and suggests ramping; spend
rails keep the whole loop inside a budget. The deep dig stops being a
thing the operator remembers to do in a terminal and becomes a thing
the fleet asks for when the board runs dry.

## The starting catalog

Two entries, deliberately, because two instances prove the catalog
shape (position 4):

1. **backlog-sweep** -- the port of the five-miner sweep: mine
   (spec/docs/code/closed-issues/adversarial-gaps) -> merge -> verify
   -> draft (matching `.github/ISSUE_TEMPLATE`, conventional titles,
   the repo's labels) -> critique -> filing gate. First because its
   output feeds the fleet directly.
2. **deep-report** -- the research shape: multi-angle search -> claim
   verification (every named project fetched and confirmed; the
   hallucination filter) -> per-dimension analysis -> synthesis into
   one standalone markdown report saved to the workspace and linked
   from the feed.

## Non-goals

- **User-authored orchestration scripts.** The catalog is code-reviewed
  data in the repo (later: TOML under the design/003 layout). If a
  workflow needs arbitrary control flow, it is not a custode workflow.
- **Parallel-by-default.** `:workflows` concurrency ships at 1.
- **Nodes that write.** No node opens PRs, edits files in target repos,
  or files issues mid-run. Analysis in, drafts out, gates decide.
- **Oban Pro.** The DAG walker is a few dozen lines over plain Oban;
  the Pro Workflow plugin is a paid dep the seam must not grow.
- **A workflow engine in oban_claude.** This is app-layer. The
  extraction trigger is the standing rule: the first second app that
  wants it.

## Relationships

- **#120 (schema-forced structured turn reports)** blocks this: node
  results ARE `--json-schema` outputs; that machinery lands there.
- **#193 (repositories page)** is where the button lives; the pages
  can ship in either order but the button wants the page.
- **#39 (growth inventory)** must cover `workflow_node_results` and
  report artifacts from day one -- runs are big and accumulate.
- **design/002 (storage doctrine)** governs where results and reports
  land; **design/004** supplies the suggestion grammar and the Digest
  builder the estimate and dryness signals read from.

## Slices

1. `Custode.Workflow` definition + runner + results table, launched
   from iex only. backlog-sweep defined but gated behind the operator.
2. The launch gate with the spend estimate + the run's budget rail +
   feed/checklist rendering.
3. The button (repo panel now, repositories page when #193 lands).
4. The suggestion path off the backlog-dryness signal.
5. deep-report, and whatever catalog-shape cleanup the second instance
   demands.
