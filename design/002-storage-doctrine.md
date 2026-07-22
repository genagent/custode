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
