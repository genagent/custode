# 002: Storage doctrine — records in the db, messages in files

Status: adopted (decided 2026-07-21 in #43; written down after the feed
move proved the rule)

Custode keeps two kinds of state and refuses to blur them. This doc names
the rule so every future "where does this live?" is answered by
classification, not debate.

## The rule

**Records live in the database.** A record is lifecycle state the machine
queries or mutates: jobs, gates, spend, memories, todos, journal entries,
feed entries, the instance heartbeat. Records need transactions, indexes,
and concurrent access from telemetry, LiveView, and MCP at once. Oban
forces SQLite to exist anyway, so the marginal cost of a table is near
zero and backup stays one file.

Current inventory (all conforming): `oban_jobs`, `gates`, `spend`,
`memories`, `todos`, `journal_entries`, `feed_entries`, `instance`.

**Messages and rendered views live in files.** A message is text written
once for an agent or a human to READ: inbox notes, the `journal.md` /
`TODO.md` workspace views, per-agent MCP config files, the operator token.
Files are the agent-native medium — claude reads an inbox note with its
Read tool, no MCP round trip, no schema. Views are regenerable from
records at any time; deleting one loses nothing.

The test when something new appears: **does the machine query it back, or
does someone just read it?** Queried → table. Read → file. If it starts
as read and grows queries (the feed's story), that is the signal it was a
record all along — move it.

## Case law

- **The feed** began as `feed.jsonl` and accumulated per-agent queries,
  pagination, and rotation pain (#20). It was a record wearing a file
  costume; #44 moved it into `feed_entries` behind the unchanged
  `Custode.Feed` API, with an optional jsonl mirror kept purely for
  `tail -f` ergonomics. The mirror is a VIEW, not a store — nothing reads
  it back.
- **Inbox notes** stay files even though the funnel tracks their filed
  state: the reader is an agent's Read tool, the writer writes once, and
  the FILED marker is metadata about a message, not a queried record.
- **The instance heartbeat** (#77) went straight to a table: it is
  queried on every boot and mutated every 10 seconds — a record by any
  reading of the test.
- **Prompt answers** (#138) were conversation stranded in process memory;
  they are records of a conversation the operator queries later, so they
  belong on the feed entry in the db.

## Distribution note

Ecto keeps the Postgres door open (adapter swap; Oban's transactional
claim is built for multi-node), BUT custode agents run the claude CLI
against LOCAL checkouts — `working_dir` is machine-bound. The likely
distributed shape is therefore **federation**: one custode per machine,
each with its own SQLite, exporting feed/status/gates to a single pane of
glass — not one shared database. That favors SQLite-per-node
indefinitely and locates the real distribution problem in the agent
processes, not the data.

## Migration versions are timestamps, never hand-numbered

Added 2026-07-26, after two outages in one day (#309, #319).

**Use `mix ecto.gen.migration`. Never pick a version by hand.**

The convention that produced both outages was `YYYYMMDD` plus a
hand-incremented counter:

```
20260726000001_add_issue_drafts.exs
20260726000002_add_asks.exs
20260726000003_add_workflow_runs.exs
20260726000004_add_disowned_prs.exs
```

Two branches adding a migration on the same day pick the next counter
INDEPENDENTLY, because neither branch contains the other's file. They
collide by construction. Ecto then refuses the entire migration run, not
just the offending pair, so the fleet does not boot.

`mix ecto.gen.migration` generates `YYYYMMDDHHMMSS`. Two authors would have
to create a migration in the same SECOND to collide. Same width, same
sortability, no coordination required.

Existing files stay as they are. Renaming a migration a database has already
applied rewrites recorded history, which is why neither #309 nor #319 did it
to anything already run.

### Repairing a branch-only applied migration

Issue #355 records the exceptional case: parked commit `5a41a5f` added
`agent_panels.kind` as migration `20260722000004`, and one live database
applied it even though panel v2 never shipped. Do not delete that version from
`schema_migrations` or rename its file. Main carries the historical migration
as an explicit compatibility tombstone, followed by a freshly generated
timestamp migration that removes the unused column. A fresh database runs
add-then-remove; an affected database skips the recorded add and runs remove.
Both arrive at the declared v1 schema, and SQLite preserves the panel rows
while rebuilding the table.

Before applying the repair to an affected SQLite database, take an online
backup:

```sh
sqlite3 custode.db ".backup 'custode.db.before-panel-kind-repair.backup'"
mix ecto.migrate
```

Verify the backup with `PRAGMA integrity_check`, and retain it until the
repaired application has booted and the existing panels have been read.

### Why this is a doctrine and not a lint

There is no check that can distinguish the two styles. `20260726000004` is
fourteen digits and parses as a valid timestamp (00:00:04), so a format rule
cannot tell a counter from a clock.

Nor can CI prevent the collision. A pull-request check comparing new versions
against `main` sounds right and does not work: #316's CI completed at
20:21:17Z and #315 merged at 00:10:54Z, nearly four hours later, so #316's
run could not have seen the file it would collide with. The usual answer,
requiring branches to be up to date before merging, needs branch protection,
which this repository cannot enable while it is private on a free plan.

So prevention is the convention, and the response chain is what catches the
rest of the time:

1. `mix custode doctor` refuses the boot and names both files (#312). This
   is the line that matters, because it fires before anything stops.
2. CI on `push: main` goes red, because `mix test` migrates a fresh database.
3. `Custode.Attention`'s `:red_main` (#310) then puts that red build in the
   operator's needs-you group instead of leaving it in a log nobody reads.

That chain is now complete, and it was assembled the same day by walking
backwards from the first outage. The convention above is what stops it from
being exercised.

## Home

Orthogonal to engine choice: at packaging time (#41 / design 001 slice 5)
everything roots under `$CUSTODE_HOME` (default `~/.custode/`) — db, feed
mirror, workspaces. cwd-relative stays fine for the source-repo phase.

## Non-goals

- No migrating messages into the db for tidiness. The agent-native medium
  is the point.
- No second record store (no ETS-as-truth, no state files). ETS is cache
  and boot-scoped identity only (`Custode.MCP.Identity`, which is
  DESIGNED to lose state on restart).
- No Postgres until federation actually ships a second node, and maybe
  not then.

## Authored subject documents (design direction, 2026-10-04)

The bounded spike in design/021 adds one narrow distinction: externally authored
preferences, research, plans and decisions may use ordinary Markdown in a
configured Git working tree as their source, including uncommitted edits. Search
indexes and summaries of those documents are derived, not authoritative records.
Operational notebook memories, todos, journals, gates, receipts and scheduling
remain in SQLite; journal.md and TODO.md remain generated views. No existing
records migrate under this amendment. Production document operations and scoped
output grants are follow-up work; automatic replacement of existing documents is
not enabled by the spike.
