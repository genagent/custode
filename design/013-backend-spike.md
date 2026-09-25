# 013: One session, one work record

Status: spike, 2026-09-25, revised after three critics. Design only, no code. Oban on the BEAM is the assumed backbone per the brief, which fixes the runtime to Elixir; no further platform decision and no merge with campo or varco is decided here. Facts cite main 5767ec8; judgments are marked.

## Purpose

The operator's brief: "custode but just the backend, simplified where possible for work coordination across agents." The target: one interactive session (Claude Code or Codex) represents the operator to a running server, hands work off, and keeps track of it. The server runs work in the four shapes the operator named: a single agent with a single run; a group of agents coordinating; a mechanical pass at a lower model and effort; a deep pass that fans out, verifies and synthesizes. Team is served by the deep shape's fan-in and by `SubAgents` inside a turn; a standalone team shape waits for a fan-in no deep run covers. The enemy is session proliferation: finishing work must never require opening another session.

"Backend" means everything under `lib/custode` except the web stack, of which one route survives. The honest title for the result: custode's backend narrowed to one client and extended with a work handle, not a simplified backend. The routine path grows; the kernel, which already writes nothing (`github_issue_intake_pilots` is `%{}`, design/010 decision 2), stays frozen, since deleting inert code does not simplify the running system.

The server is not a second interactive session, a claim broker between sessions, an application UI, or a runner for the operator's own checkouts. Judgment: the agent server already runs (Oban 2.24.1, oban_claude 0.7.0, oban_codex 0.5.0); the session lacks a handle.

The delta, against 32 tables plus `oban_jobs`, 78 `ToolPolicy` entries, four queues and about 60k lines under `lib/custode`:

| | Tables | Tools | Queues, jobs | Modules |
|---|---|---|---|---|
| Dropped, live | `agent_panels`, `issue_drafts` | panels, drafts, suggestions, advisors, metrics (8) | haiku probe and advisor crons | advisors, suggestions, metrics, panels, uploads, drafts, archetypes, launch gate, nine LiveViews (about 20) |
| Dropped, inert | none: the kernel (13 tables, 26k lines) stays frozen | none | none | none |
| Added | `work`, `runs`, `projects`, `operator_state`; 9 columns | `submit_work`, `work_status`, `stop_work`, `changes_since`, `ack_changes`, `tell_agent`, `register_project`, `repo_set_labels`, `resume_work`, `recover_gate`, 7 git reads (17) | `reviews` 1; `GateVerdictJob`, `ProjectRefreshJob`, `Work.Ingest` | Work, Work.State, Work.Ingest, Projects, ProviderArgs, git reads, `/decide`, two jobs |

Net: two live tables fewer, nine tools more, one queue more, a similar module count with weight moved from UI to coordination, plus prompt text (Rungs). The operator judges whether that is simpler.

## The model

| Name | What it is | What it records |
|---|---|---|
| Work (new) | One piece of work a session handed off; a scheduled sweep has none | `shape`, `workflow`, `brief`, `brief_digest`, `initiative` (provenance only), `repo` or `subject`, `issue` (with `repo`, the claim key), provider, model, effort, `budget_tokens`, `max_turns`, `prs`, `maintained_by`, `worktree`, `notes` (replies, answers, lessons), `outcome`, `finished_at`, `result` (summary plus the `journal_entries` ids whose new `arc_id` is this run's). |
| Run (new) | One carrier execution of a Work | `work_id`, `carrier` (`agent_turn`, `workflow_run`), `carrier_id`, `spend_key` (`work-<id>`, or `workflow-<run_id>` per `workflow/run.ex:160`), `arc_id`, `status`, `started_at`, `ended_at`, `paid_twice`. One handler, `Custode.Work.Ingest`, writes it on `[:agent, :turn_completed]` and `Workflow.Run.complete/fail` and stamps Work `outcome` and `finished_at` at the shape's terminal condition |
| Work agent | A `sub_agents` row `work-<id>`, `parent: operator`, new `work_id` column | Provisioned by the existing `start_agent` path (token, MCP config, spawn row), extended: `Capabilities` admits a sub-agent whose row carries `work_id` to `:main` with the worker set (today `/mcp/memory` only, `capabilities.ex:64-69`); a workspace `<root>/workspaces/work-<id>/` with `inbox/`; `Gates.reconcile!` requeues it; `Repository.ensure_served(repo, :project)` serves it (keyed by routine today, `repository.ex:84`); `Grant.check/2` already keys on the caller id. Never in `Routine.all/0` or the `Scheduler`; never auto-revived: boot writes a restart note and `work_status` shows `continued: fresh` |
| Gate, ask | `gates.ex`, `asks.ex` | Both gain `work_id`; an open ask keeps its Work non-terminal. Gate gains `would_approve`, `verdict_reason`, `superseded_by`, `in_reply_to_note`, `continuation_lost`. Seven new feed writers, `gate_resolved` to `refresh_skipped` |
| Project (new) | One row per repository | `remote`, `checkout_path` (`<root>/checkouts/<owner>/<repo>`); seed: `OwnedCheckout` (#622 to #629) |
| Operator state (new) | One row | `last_seen_feed_id`, advanced only by `ack_changes`; its `updated_at` joins `Presence.recent_operator_actions/1` (`presence.ex:228`) so an active session reads present |

Not in the model: leases, a phase graph, a subject table (a subject is a manual routine, design/010 decision 1), a rules table, a messages table. A `tell_agent` note is an inbox file whose `note_id`, `from`, `in_reply_to` and `work_id` go on the `inbox_note` feed entry at drop time; `awaiting_reply` derives from the feed, never from files (design/002).

The claim is mechanical where the verb guarantees (design/000): `Repository.open_pr/2` refuses when a live Work names (repo, issue) and the caller is not that Work's agent; `Gates.open/2` marks an `implement` gate whose `issues_touched` collide with live Work; `submit_work` refuses a second live Work on the key. #428 (two paths, one issue, the same diff twice) is why the Handoff hint alone is not enough.

Live state (`queued_behind`, `waiting_behind_gate`, `needs_answer`, `awaiting_reply`, `requeued`, `rescued`, `budget_paused`, `continued`) derives in one pure module, `Custode.Work.State` (design/007), read by `work_status` and by `Custode.Attention`.

Terminal conditions: single on a repo ends when its PR is merged or closed, or on `stop_work`; mechanical and subject single end when the turn finishes with no open ask; deep ends when the synthesize result is persisted. `awaiting_reply` past 24 hours (the `Aging` ladder's top) becomes `work_failed: no_reply` naming the counterpart; `work_failed` with a terminal `TurnFailure` category joins `Aging`'s ladder: a timer, not a caretaker turn.

## The vocabulary

| Operator's term | This design (and the custode piece it already is) |
|---|---|
| Agent server | The node: queues, agent supervisors, `Scheduler`, MCP on 6161 |
| Agent pool | Roster plus free slots on `agents` 5; Work agents and sub-agents are temporary members |
| Agent team | A deep run's synthesize fan-in, or a routine turn using `start_agent` (#639). Not a shape |
| Agent mesh | `tell_agent` at worker tier over `Inbox.drop/3` (`drop_note` is `:operator` tier today, `tool_policy.ex:98`; #461) |
| Shape: single | A Work agent on a registered repository; on a subject, one turn of its manual routine via `message/3` |
| Shape: mechanical | A Work agent under the `mechanical` profile (model, effort, `max_turns`, verb list, no shell) on `agents` at priority 1 |
| Shape: deep | A `Custode.Workflow` run (Claude-only today) on the existing `workflows` queue at 1 (`node_job.ex:10-16`) |

campo's concepts are a client vocabulary of this server: session to the operator token, work item and claim to Work, work entry to Run, message to the note, event to the feed entry, space to a project or subject, actor to an identity kind.

## Operations

All are functions in `lib/custode/operator/` (design/010 decision 4) with an MCP tool over each. The session holds the operator token only; a session header is claimed, not verified (`identity.ex:5-6`).

| Operation | Gated | Records |
|---|---|---|
| `submit_work(shape, brief, repo\|subject, issue?, workflow?, provider?, model?, effort?, budget_tokens?, max_turns?, initiative)` | No: operator-initiated writes execute directly, `initiative` recorded (`Authority.roster_write` admits the operator today, gating only the caretaker) | Work row, then the carrier: `Agents.start_agent("work-<id>", args)` for repo Work, `message/3` for subject Work, `Workflow.Launch` for deep. Idempotent on (caller, `brief_digest`, target, shape). `repo:` requires a project; a subject's routine is created on first use (`WriteBack.add_routine/1`). Codex refused until rung 5 |
| `work_status(work_id?, filter?, wait_ms?)` | No | `Work.State`, runs, gates, asks, PRs, worktree, the next expected gate; cost as tokens by `spend_key` and turns; fleet utilization only as context |
| `stop_work(work_id)` | No | `Oban.cancel_all_jobs` by `meta.work_id`, Work agent stopped, `maintained_by` to the repo's routine if scheduled |
| `changes_since(cursor?)`, `ack_changes(through_id)` | No | Feed by id; no cursor means since the operator's ack, or the last 24 hours for a fresh session; only `ack_changes` advances `operator_state` |
| `tell_agent(to, body, in_reply_to?, work_id?, urgent?)` | No | `Inbox.drop/3` with `on_note: :ignore`; `urgent` wakes once (rung 4) |
| `register_project(remote)` | No, for the operator | Project row; clone under the root; `ensure_served(repo, :project)` |
| `repo_set_labels(repo, number, add, remove)` | `{:repo_write, :set_labels}`, class `triage` | New verb: nothing sets a label today (`mark_issue_*` post comments, `repository.ex:161-166`) |

Seven git reads (`git_status`, `git_log`, `git_diff`, `git_blame`, `git_grep`, `git_show`, `git_ls_files`) run over the server's clones under `Scope`. `operator_bootstrap` (#647) gains `root` and `token_path` (`bootstrap.ex:14` holds neither today). The operator token is decided long-lived: `<root>/tokens/operator`, rotated only by `mix custode rotate-token`; routine and sub-agent tokens stay per boot (`identity.ex:7-12`), so a restart changes nothing the session holds. The CLI keeps `doctor`, `drain`, `changes` and `config print`, which prints the MCP entry and an AGENTS.md block telling the model to call `changes_since` and `ack_changes`, and writes nothing.

## How work moves between agents

**S0: the Work agent.** `submit_work(shape: mechanical, repo: R, brief: relabel forty issues)`: Work row, sub_agents row, `start_agent` on `agents` at priority 1 under the `mechanical` profile. The directive schema is the routine one minus `ask_user` (asks go through `ask_operator`), so a queued brief is never read as an answer. It raises one `triage` gate, like a routine, whose card lists all forty; a mechanical batch is decided all or nothing, which is why Drafts is dropped. Nothing is pre-approved: a pre-approved row approves an action nobody described. The profile is a ceiling (`Grant.approval_args/2` merges under it), so a mechanical continuation never gains a shell. `triage` (`set_labels` plus the two `mark_issue` verbs) ships with rung 1a pending #555; without it `:enforce` refuses `set_labels` as `:outside_class`. An ask ends the turn as `needs_answer`; the answer lands in the Work agent's inbox and resumes its operator arc.

**S1: implement, review, merge.** Under `:enforce`, which S4 needs, `open_pr` belongs to `implement` (`class.ex:64`), so S1 has three gates.

1. X's Claude routine sweeps in the clone and proposes `implement`; no rule clears a shell class. `open_pr/2` refuses an issue a live Work holds.
2. Approved, the continuation runs in a worktree, opens a draft PR, proposes `ready_pr`. `GateReviewJob` moves from `:agents` (`gate_review_job.ex:5`) to `reviews` at 1. Morning: `changes_since` shows the gate with its review; `approve_action` stamps who and via.
3. Merge: `merge :manual` (`repository.ex:502`) becomes merge gated, and `review_floor` (`repository.ex:323`) is satisfied by a completed clean `gate_reviews` row for the PR's head SHA, which `Repository` reads; otherwise the verb refuses naming the rule and the head SHA. The routine proposes `merge`, woken by a `CiStatus` green transition, which is new (today the sensor notes failing transitions only, `ci_status.ex:5-7`). The operator decides merge, never a rule.
4. The sweep is told through a `Custode.Handoff` section, placed first under a 4 000 byte cap inside the 24 000 byte packet (`handoff.ex:15-17`); journal entries trim after it.

Restart between review and merge: today `Gates.reconcile!/0` (`gates.ex:432-609`) marks the row `requeued` and drops a RESTART NOTICE that wakes the routine on a debounced tick (`inbox.ex:22-26`). Kept; the re-raised gate stamps the old row `superseded_by`. Two more timings: a `requeued` gate older than one beat interval shows in `changes_since` as `needs_you` with `recover_gate`, which beats the routine with the gate text; an approved gate with `continuation_ended_at nil` at boot is stamped `continuation_lost`, a note names the worktree and PR, and the routine re-derives merged-or-not from GitHub.

**S2: a subject with no standing agent.**

1. `submit_work(shape: single, subject: travel, brief: Ligurian coast)` creates the manual routine on first use, ungated for the operator (`cron: manual`, never scheduled). Not #565's `run_job`: a one-shot has no identity, notebook or inbox; a subject needs a notebook to keep results.
2. `message/3` starts it in the `operator` arc (design/011). The notebook (`journal_append`, `remember`, self-only, ungated) is the durable knowledge; `HANDOFF.md` renders it for next week's fresh worker.
3. Two submissions at once: the second is delivered from its Work row only when the routine is `:idle`; in `:waiting_for_user` or `:awaiting_permission` it stays `queued_behind`, since the engine reads the next operator prompt as the answer.

**S3: agent to agent.** A release is no `repo_*` verb and no class (`class.ex:18-30`), so B's gate is `other`: unbounded, operator-decided, unreviewed. The win is only that the operator was not needed to ask.

1. A calls `tell_agent(B, body, work_id)`: a note, no wake; B reads it at its next beat. A manual B is refused unless `urgent`. Containment: routines and Work agents may address each other, sub-agents may not, and the caretaker sees cross-talk as `inbox_note` feed entries (#461's switchboard, by record).
2. B proposes the release; the gate carries `in_reply_to_note` in both directive schemas (`Routine.directive_schema_map/0` and the strict nullable Codex one, #681). On `gate_resolved`, approved or rejected, the server drops the reply into A's `notes`, so the answer does not depend on B's continuation. No reply after 4 hours shows `awaiting_reply`; after 24, `work_failed: no_reply`.
3. Loop guard: non-urgent notes never wake (today every drop wakes, `inbox.ex:24, 58-63`). A per-pair cap and its counter wait for a measured loop.

**S4: authority, not bottleneck.** Four gates at 07:00, the operator wakes at 14:00.

(a) Today and through rung 5. `GateVerdictJob` runs on gate open, risk and review; it reads class, risk and `review_state` against one config list, `approve_classes: [{"ready_pr", risk: :low, review: :clean}]`, and stamps `would_approve` and `verdict_reason`. It decides nothing (`grant.ex:32`, #554 open). Four waited seven hours; `changes_since` at 14:00 shows one `would_approve` stamp and three reasons. This is #451's observe-only verdict moved off the caretaker onto a job. No rules table, TOML, versions or caps: the list changes by a custode PR, itself a Work of shape single.

(b) After #554 says yes and `:enforce` is on. One `ready_pr` clears at 07:01, stamped `decided_by operator, decided_via rule:ready_pr`. A rule is delegated approval; turning it on amends design/000 (sole approver). "Policy never grants" means here that a rule approves only what the class already bounds and never widens a grant. The same rung ships `repo_unready_pr` and a `disavowed` outcome (`disavowed_at`, `disavowed_by`, excluded from the accuracy count). (b)'s evidence: four weeks of observe-only counts of stamps the operator then rejected, expected near zero given 351 to 7.

**S5: the one session.**

1. `submit_work(shape: deep, brief: bug class C on R)` runs the existing `deep-report` catalog entry (`catalog.ex`) with the brief as context, on `workflows` at 1. A new deep shape (audit, verify per item, synthesize) is a catalog entry, so adding one is a Work of shape single against the custode repository. No `Availability` at admission in week one.
2. An hour later `work_status` returns the synthesize output, tokens by `spend_key`, turns, and fleet utilization ("5h window 62%, was 41% at start, N other turns meanwhile") as context, never as the Work's cost.
3. The relabel is S0.
4. `submit_work(shape: single, repo: X, issue: N)`: the Work row is the claim; a Work agent runs in a worktree, first turn un-elevated, and raises `implement`. The PR stays the Work's: `CiStatus` green wakes `work-<id>`, which proposes `ready_pr` then `merge` in its own turns; `maintained_by` transfers to X's routine only on `stop_work` or `work_finished`.

**S6: the server's own checkout.**

1. `register_project("git@github.com:org/repo.git")` executes directly, `initiative: operator`; the server clones to `<root>/checkouts/org/repo` (`OwnedCheckout.provision/3`, `owned_checkout.ex:158`).
2. A read-only sweep runs in the clone itself (`ConversationArcs` fingerprints `working_dir`, `conversation_arcs.ex:319`).
3. `~/Code/github.com/org/repo` is never opened for a new project from rung 1a; the 12 of 22 routines on this machine whose `working_dir` is outside the root migrate at rung 3, when `doctor` refuses.
4. A worktree is removed when its branch is pushed or its diff is empty, else kept and named in `work_status` (#673). `ProjectRefreshJob` fast-forwards only when no executing turn has the clone as `working_dir` (`Custode.RunClock` holds the in-flight set) and no live shell-class grant names the project, else records `refresh_skipped`; after a refresh it rotates that routine's operator arc.

**03:00 crash.** Boot reconcile re-enqueues only deep nodes without a persisted result and marks the run `paid_twice: possible` (design/evidence/356: at least once). Process-group kill is delivered (#573 closed, forcola 0.3.3); the residual is a tool child in its own process group, so a worktree with a live process or an unpushed diff is listed `orphaned` in `work_status`, never refreshed or removed. The #573 kill test is a rung 1a acceptance item.

## What is kept from custode and what is dropped

Kept: gates with class, risk, review, stamps and grants; asks; `Operator.Actions` and `Authority`; the inbox funnel; the schedule (`Scheduler`, `RoutineTick`, `Ticks`, `NextBeat`, `BeatBackoff`); `TurnFailure`; `MCP.Probe`; `Custode.Workflow`; `SubAgents` and the delegate tools, now the Work agent path; `OneShotJob` as `run_job`'s carrier from a routine's own turn; `CrossProviderReview` (#604); sensors; feed; spend rails (a Work agent's rail is its `budget_tokens`, pausing only that agent); `Aging`, `Attention`, `Digest`, `Presence` (still in every sweep); `OperatorMessages`, `ConversationArcs`, `Handoff`; the MCP layer (#617, #637); `OwnedCheckout`, `Instance`, `ObanEngine`; the operation spine's three live definitions; the caretaker, now seeing stuck Work through `list_attention`; the kernel as frozen. One web route, `/decide`, from the console's item and question panes (#548): open gates and asks with one-click answers, the phone surface, an application page, retired when decisions via `liveview` fall below 3 a week.

Dropped: the nine remaining LiveViews (`root`, `console`, `inbox`, `feed`, `repos`, `workflows`, `workflow_launch`, `metrics`, `suggestions`; the fleet and agent pages are already gone, #553 closed); Advisors, Suggestions, Metrics, Panels, uploads, DirectoryBrowser, archetypes, the workflow launch gate, Drafts, the haiku probe (#636). `Custode.Workspace.Git` stays with the kernel (13 callers, all kernel); git_wrapper_ex replaces `System.cmd("git")` in `OwnedCheckout`, `WorktreeBreadcrumb` and `Checkout`. Oban Web is not mounted: no scenario reads a job row `work_status` does not answer; trigger: the operator asking for a queue view.

## What the runtime must provide

Rows are marked open Oban, Oban Pro, oban_claude (covering oban_codex) or built.

| Requirement | Given by |
|---|---|
| Durable queue, unique jobs, retry and cancel vocabulary, priority, static cron, orphan rescue, pruning (90 days), telemetry | open Oban + oban_claude Outcome |
| Runtime cron and stale beat discard; fan-out with barriers; await; single node per database | built, exist: `Scheduler`, `RoutineTick`, `Ticks`; `Custode.Workflow`; `OperatorMessages.await`; `Instance` (substitutes for Pro DynamicCron, Workflow, Relay, Peer) |
| Per-agent state machine, gated states, continuation, fencing, arcs; provider subprocess and process-group kill | oban_claude + wrappers, forcola 0.3.3 |
| Work, Run, Project, operator_state tables; Work agent on the `SubAgents` path (main-endpoint admission, workspace, mint at start, revoke at finish); `Work.State`, `Work.Ingest`, per-Work rail; `changes_since`, `ack_changes`, new feed writers; long-lived token, `config print`; the claim in `open_pr/2` and `Gates.open/2`; `superseded_by`, `continuation_lost`, review re-enqueue at boot; subject Work delivered into `:idle` only | built, new |
| `GateVerdictJob` over `approve_classes` (observe-only until #554); `reviews` queue; `CiStatus` green wake; `Probe` gating every provider queue, not only `ticks` (`probe.ex:3-35`) | built, new |
| Merge gated with `review_floor` over `gate_reviews`; `repo_set_labels` and `triage`; served repo per project; Handoff section; `Custode.ProviderArgs.for(provider, purpose)` for Codex Work agents and NodeJob (`CrossProviderReview.provider_args/2` is private and read-only, `cross_provider_review.ex:321`); project registry, clone by project, `ProjectRefreshJob` with the RunClock guard, containment; git reads over git_wrapper_ex (hex `git` 0.7.0) | built, new; extends `OwnedCheckout`, `Scope` |
| `tell_agent` tier change, reply on `gate_resolved`, both directive schemas; hook isolation by `hermetic(:full)` plus `CUSTODE_ROUTINE_ID` (new, set in `Routine.claude_args/2`, `codex_args/2`) | built, new, rungs 4 and 6 |

Queue rule: a job carrying operator-visible latency (reviews, verdicts, ticks) never shares a slot with a long provider turn. Queues: `agents` 5 (Work agents at priority 1), `ticks` 1, `sensors` 2, `workflows` 1, `reviews` 1.

Lite engine: one node per database, no global or rate limits, no Reindexer, no advisory-lock uniqueness (`deps/oban/lib/oban/engine.ex:17`; `lifeline.ex:15`), `SQLITE_BUSY` on ack retried by `Custode.ObanEngine`. Postgres later changes the engine and notifier and no row, operation or path. A second node is a separate decision touching `Instance`, the `:global.trans` checkout locks, ETS identity and every `<root>` path; design/002 argues for one server per machine instead.

## The workspace

The server owns one root, `Custode.Home.root/0` (`$CUSTODE_HOME`, `home.ex:26`):

```
<root>/
  custode.db                  one SQLite file, Oban included
  routines.toml               roster and shape profiles
  tokens/                     operator token (0600, long-lived), routine configs
  checkouts/<owner>/<repo>/   clone per project
  worktrees/<id>/             continuations, shell-shape Work
  workspaces/<routine>/       notebook views, inbox/, HANDOFF.md; work-<id>/ too
```

git as a service, decided: reads only, over git_wrapper_ex. A worker uses log, diff, blame and grep for review and audit, status and diff for a report. No shell: mechanical, review, deep nodes, subject research; a shell: `implement` and `pr_maintain` (`Class.shell?/1`), sized by class (#515). `repo_*` stays the remote side.

Two machines: a session's MCP entry names one loopback server, Work rows and claims are per database, and a project is registered on one machine only, by discipline until federation. `approve_classes` lives in `config.exs`, so it is identical on both.

## The operator as authority, not bottleneck

Numbers: 351 approved, 7 rejected; median wait 5.9 minutes, p90 90, worst 13.5 hours, 71 over an hour.

In order: `GateVerdictJob` stamps `would_approve` now, so #554 is decided on a count; under `:enforce` a rule clears low-risk reviewed `ready_pr` on fleet-opened PRs; `Aging` re-notifies gates, asks and terminal `work_failed`. `initiative` is provenance (design/012: a conversation with the session is not implicit approval) and never an input to a rule: a rule may require a human decision (`decided_via mcp` after a gate) but not a claimed initiative.

The operator's alone: every shell class, `merge`, `comment`, `file_issue`, `review`, `triage`, roster and profile writes, `drain`, `set_presence`, asks, any gate with risk `nil` or outside the list, and turning `:enforce` on.

## Relationship to custode, campo and varco

Under the pause premise: if custode stays paused, campo plus varco keep the vocabulary and the runner and lose the gate with a recorded decision, the schedule, durable runs that outlive a session, and the caretaker. campo covers better: verified session identity, delivery measured with `via`, claims between many sessions. Paused either way: the kernel, missions (#459), routing (#575), the console beyond `/decide`, the catalog (#578).

The division, argued from the scenarios: one system. S5 needs a server that runs work in shapes and keeps a schedule; campo runs nothing and varco keeps nothing durable. S1 and S4 need an authority record with class, risk and grant; only custode has one. So the server is custode's backend narrowed, the runner oban_claude and oban_codex, the record SQLite, the front door MCP. design/012's connection protocol (`operator_bootstrap`, idempotent messages, exact-receipt `await`) is the `submit_work` protocol; Work is a handle above an `OperatorMessage`. Of #451's open items, the caretaker verdict moves to `GateVerdictJob`, enforcement stays #554, and "custode decides a sibling's gate" closes as not planned: a rule decides, never an agent.

campo does not run in the operator's session while this server is in use: two records of one piece of work is campo's own trap one. Forgone: session resolution from process ancestry, hooks under 50 ms, `via` delivery measurement; trigger to revisit: a second interactive session. varco is not run: oban_claude and oban_codex already wrap the same two CLIs.

Prior art: beads' items-plus-claim primitive is the one every fork kept; the Work row is the claim. Gas Town's convoy is the batch record; the workflow run row already is one. Gas Town's standing LLM sessions as infrastructure are the proliferation to avoid: the caretaker is the only standing meta-agent, and rules, not a session, clear gates.

Ideas that carry: the tree is the permission model; write-shaped work stops at a gate whose card shows the exact action; a rejection reason teaches; an ask is not a gate; a note is an event, never a command; records in the database, views in files; cheap sensor, expensive brain; policy narrows and never grants; a bounded, digested brief per run, landing as `brief` and `brief_digest` on Work (design/009 claim 3).

## Rungs

Each rung's benchmark is design/009's: fewer paid turns, gates and surfaces per scenario than the routine path plus `run_job`. A rung starts when the previous one is boring.

Day 0, by hand, once, about an hour: `mix custode rotate-token`; `config print claude|codex`, pasted into the session's settings; `register_project` for the first repository.

1a. **Work and the handle.** The Work, Run and `operator_state` tables; `submit_work` for single and mechanical (a Work agent in a worktree of the repository's existing owned checkout via the wrapper's `worktree:` option) and for deep on `deep-report`; `work_status`; `changes_since` over the existing feed; `repo_set_labels` and `triage`; the claim in `open_pr`; the `CiStatus` green wake; the long-lived token and `config print`. No new queue, worktree split, merge policy change, hook or service. Prompt delta: the mechanical profile's no-shell text, "read open Work from your handoff", the brief template. Estimate: 3 tables, 6 tools, about 2.5k lines. Benchmark: a week from one session on the relabel, one fix and one deep report, counted in paid turns, gates and sessions opened.

1b. **Finishing.** Merge gated with `review_floor` over `gate_reviews`; the `reviews` queue; `superseded_by`, `continuation_lost`, review re-enqueue; the launchd service and `server_down`. Benchmark: S1 end to end without GitHub's UI.

2. **The workspace.** `projects`, clone by project, the worktree split, `ProjectRefreshJob`, git reads over git_wrapper_ex replacing `System.cmd` in three live modules. Benchmark: S6 with no read of `~/Code`.

3. **Migration.** The checkout migration on both machines; `doctor` refuses `working_dir` outside the root. The kernel stays frozen.

4. **`tell_agent`** as a tier change, `in_reply_to_note`, the reply on `gate_resolved`. Benchmark: S3, Claude to Codex, no operator turn before the gate.

5. **`GateVerdictJob`** in observe mode over `approve_classes`, the Handoff section, `Probe` on every provider queue, Codex Work agents and NodeJob through `ProviderArgs`. `:enforce`, `repo_unready_pr` and `disavowed` are #554's rung.

6. **The hook**, only after the pull model has failed the operator once: `custode hook claude|codex` prints entries that name the operator (open gates and asks, `work_finished`, `work_failed`, `server_down`, rule decisions), newest first, under 2 KB with a count of what was omitted; `host_session_id` from the payload is claimed and used only as a cursor key; workers are sealed with `hermetic(:full)` (never `--bare`: API-key billing, `claude_wrapper/query.ex:412`) plus the `CUSTODE_ROUTINE_ID` exit.

The abandonment day, named: on the previous plan it was before Monday (1a was weeks of building). On this plan it is Wednesday of week one, when the Work agent's `ready_pr` review waits behind long turns on `agents` and the operator finishes the PR on GitHub.

Operating note (AGENTS.md): 1b changes what an approved turn may do and 1a the token lifetime; each lands on a running fleet by pull, `doctor`, migrate and a scheduled restart. The session may be Codex from day one; workers are Claude-only through rung 5.

## Deferred

- A `release` class; git writes on a worker's behalf; `steer_work`; a messages table and the urgent cap (trigger: a measured loop); a team shape (trigger: a fan-in no deep run covers); `Availability.advise` at Work admission (trigger: a Work hits a rate limit); rule reload without restart (trigger: the first enforced decision); Oban Web; missions (#459); routing (#575); the catalog (#578); remote and headless operation; MCP parity as a program; kernel deletion.
- A second interactive session and its claim race; federation across the two machines.

## Questions for the operator

In order:

1. #555: a `triage` class for `mark_issue_ready`, `mark_issue_blocked` and `set_labels`? Without it `:enforce` refuses the relabel.
2. Merge gated in place of `merge :manual`, with a clean cross-provider review satisfying `review_floor`?
3. #554: after four weeks of `would_approve` counts, turn on `:enforce` with a rule deciding only reviewed low-risk `ready_pr`, amending design/000?
4. Migrate `checkouts/<routine-id>` to `checkouts/<owner>/<repo>` on both machines, this one first?

Decided here, not asked: the long-lived token; no pre-approved gates; one web route.

## What this does not solve

- Delivery into the session is pull: the model must call `changes_since`; a session that never acks reads the last 24 hours on its first turn. The hook is rung 6.
- An ask or a `work_failed` while the operator is away waits for `/decide` on a phone or the next session; ntfy is on hold.
- Two sessions at once: one operator token, no claim between them. Two machines: one project per machine by discipline.
- The 98% approval rate may reflect that a human was watching; the observe-only count is the evidence.
