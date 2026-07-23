# 001: Auto-setup — routines beyond source, config staying the truth

Status: proposed (operator-drafted 2026-07-21, synthesizing #41 and #75)

The fleet's routines are compile-time Elixir data in `config.exs`. That was
right for a source-repo demo and is wrong for both futures we want: a
shippable binary (#41) and setup-as-a-conversation (#75, "watch
joshrotenberg/foo like the others"). This doc makes the decisions the two
issues left open and cuts the arc into one-sweep slices.

## The invariant everything hangs on

**One truth, and it is a file in version control.** Every path here — TOML
loader, write-back, MCP tool, dashboard form, meta-agent proposal — preserves
the property that the complete routine roster is a single diffable artifact a
human can read in git. Two stores (config for some routines, a db for
UI-created ones) is the drift machine #7 warned about; phase 3's db-backed
CRUD (from #41) is explicitly DEFERRED until something real demands it.

## Decisions

### D1. `routines.toml`, and when present it wins outright

Phase 2 of #41 as written, plus a resolution rule the issue left open: if a
routines file exists (`--config PATH`, `$CUSTODE_CONFIG`, then
`./routines.toml`), it is the WHOLE routine+sensor roster; the `config.exs`
`routines:`/`sensors:` lists are ignored, not merged. Merging two sources is
drift with extra steps. `config.exs` keeps infrastructure only (ports, db
path, policies, profiles — see D2) and serves as the roster fallback when no
file exists, which keeps the source-repo dev loop unchanged.

TOML over JSON because operators edit this file and comments are
load-bearing (every TEMPORARY crank tonight carried one). Dependency: the
`toml` hex package, boot-path only.

### D2. Profiles and prompts stay in code; the file carries assignments

The #38 vocabulary earns its keep: charter and role bodies are code
(`Prompts`), profiles are named envelopes (config), and `routines.toml`
carries ASSIGNMENTS — the five-line id/profile/repo/working_dir/tags shape
that every worker tonight already has. A file entry never embeds a prompt
body; `system_prompt_file` references stay paths. This keeps the file small,
reviewable, and renderable by machines (D4) without template soup.

### D3. Loading is `runtime.exs` → `Application.put_env`; the choke point holds

`Custode.Routine.all/0` already funnels everything through
`Application.fetch_env!` + `normalize/1` (routine.ex:17). The loader parses
the file in `runtime.exs` and `put_env`s the same shape the exs lists carry
today — nothing downstream changes, releases work (no Mix at runtime), and
`normalize/1` remains the single place the shape is defined.

### D4. Write-back is file + env in one gated operation

The new-agent flow (any surface) funnels through one module:

    Custode.Config.WriteBack.add_routine(attrs)
      1. normalize/validate attrs (same checks normalize/1 applies)
      2. render a TOML section and append to the routines file
      3. Application.put_env the updated roster

Step 3 is what #121 (fire-time tick args) was waiting for: because cron
resolution reads the env at every fire, an edited routine is live at its
next beat with no restart. A NEW routine is immediately beatable and
Repository-served; only its cron entry waits for the next restart (Oban Cron
reads the crontab at init — honest and simple, per #75; a dynamic scheduler
or #34 hot reload closes that later, and #132's drain makes the restart
cheap meanwhile).

If no routines file exists yet, the first write-back CREATES it by rendering
the current in-memory roster — migration is a side effect of first use, not
a project.

### D5. Every write-back is gated, and policy applies

An agent-proposed add flows through `request_permission` like any write —
the gate card shows the RENDERED TOML section, so what the human approves is
literally the diff. A human-driven add (mix task, dashboard form) is its own
authority but produces the same artifact. The policy layer gets a hook:
rules scoped to config mutations (example from #75: `:external`-tagged
routines may only be human-created). The caretaker's fleet-conventions
orders already teach the interim recipe; when D4's tool exists, those orders
swap "draft the entry and hand it to the operator" for "propose add_routine
with the rendered entry."

### D6. The conversational endgame is an orders change, not a feature

"custode, watch redis/redisctl like the others" already almost works — the
caretaker checked access, gated the clone, and drafted a config entry
tonight, by hand, from its conventions orders. With D4/D5 in place the
endgame is one sentence in the caretaker's orders: propose `add_routine`
instead of journaling a draft. No new machinery.

## Slices (in order; each one sweep)

1. **feat: routines.toml loader** — `toml` dep, runtime.exs loader with the
   D1 resolution rule, file-wins semantics, tests for both sources. The exs
   dev loop keeps working untouched.
2. **feat: Custode.Config.WriteBack + `mix custode add`** — render, append,
   put_env; creates the file from the live roster on first use; property
   test: write-back then reload round-trips the roster.
3. **feat: add_routine MCP tool + gate flow** — the tool renders the section
   into the gate description; policy hook for config-mutation rules;
   caretaker orders updated to propose instead of draft.
4. **feat: dashboard new-agent form** — the same WriteBack, human authority,
   profile dropdown + the five assignment fields.
5. **chore: binary-readiness pass** — `--home DIR` rooting workspaces/db/
   config, doctor as install preflight (#15), per #41's binary notes.

Slices 1–2 unblock everything and are workable now; 3 depends on 2; 4 and 5
are independent after 2.

## Non-goals

- No db-as-truth (phase 3) until the file model actually hurts.
- No merging of exs and toml rosters, ever (D1).
- No prompt bodies in the routines file (D2).
- No dynamic cron scheduler in this arc; restart-activated schedules with
  #132 drain are acceptable until #34 decides otherwise.
