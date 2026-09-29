# custode

An always-on fleet of scheduled LLM agents with one human operator, built on
the `ObanClaude.Agent` layer of
[oban_claude](https://github.com/genagent/oban_claude). Each agent is a
long-lived `claude` session wrapped in an OTP state machine, run on a cron by
Oban, usually one agent per GitHub repository. The operator watches, talks to
and approves the fleet from a LiveView dashboard, a CLI, or MCP.

The model in one line: **operator** (the human, who approves every write) ->
**custode** (the caretaker meta-agent) -> **specialists** (one role per
repository) -> **sub-agents** (ephemeral delegated hands). The tree is the
permission model. It is written up in
[design/000-the-operated-fleet.md](design/000-the-operated-fleet.md); the
current plan is
[design/010-back-to-the-dashboard.md](design/010-back-to-the-dashboard.md).

**New here?** [guides/demo.md](guides/demo.md) is the 0.1.0 quickstart: a
fresh home, one agent with its own clone, one task through a gate to a draft
pull request, the same steps over MCP, and a restart.

## Cost

Every turn is a real `claude` call against the logged-in plan. The dashboard
header shows plan utilization (5 hour and 7 day windows) and today's spend.
Each routine has a per-turn cap (`max_budget_usd`) and a daily rail
(`daily_budget_usd`) that pauses it when crossed. A fresh checkout runs
nothing until you add a routine.

## Prerequisites

- Elixir ~> 1.20 / OTP 29
- the `claude` CLI, logged in (`claude login`), and/or the `codex` CLI,
  logged in, for Codex routines. `mix custode doctor` checks only `claude`;
  on a Codex-only host see [the demo guide's preflight](guides/demo.md#3-migrate-preflight-boot)
- the `gh` CLI, authenticated
- local checkouts for agents configured to use an existing checkout; the
  dashboard can provision routine-owned clones instead

## Run it

```sh
mix deps.get
mix ecto.migrate
mix custode doctor                        # preflight: claude, gh, migrations, checkout
mix phx.server                            # dashboard :4646, MCP 127.0.0.1:6161
```

Custode installs Snodo, `oban_claude` and `oban_codex` from Hex. To test
unreleased wrapper changes, set `OBAN_CLAUDE_PATH` or `OBAN_CODEX_PATH` to the
matching local checkout before running `mix deps.get`. Each override is
independent.

The roster lives in `routines.toml`, which is gitignored: a routine names a
repository and a working directory on one machine. With no `routines.toml`
the node boots an empty fleet and says so. A routine can also be added from
the dashboard ("new agent") or by asking custode; both write the same file.
`config/config.exs` holds defaults and role profiles only.

On an empty fleet, open the dashboard and choose the first agent. The fleet
caretaker is recommended because it enables the Custode conversation surface,
but backlog workers, stewards, specialists, tutors and bespoke agents are also
available. Setup shows provider, cadence, resolved model and rails before it
writes anything. Repository agents can use a Custode-managed clone under the
data directory or an existing host checkout selected with the directory
browser. Configure additional browser roots with `config :custode,
checkout_roots: ["/path/to/code"]`.

For a second machine, a separate state directory (`CUSTODE_HOME`) and phone
access, see [guides/install.md](guides/install.md).

Stop it with `mix custode drain`: queues pause, executing turns finish, the
node exits. A second boot against the same database refuses while the first
is alive.

## Setup and troubleshooting

The complete fresh-machine sequence is in
[guides/install.md](guides/install.md). Start diagnosis with the two checks
that know their respective layers:

```sh
mix custode doctor   # Custode, provider login, GitHub, home, roster, managed settings
claude doctor        # Claude Code settings and rejected configuration
```

Do not paste `tmp/operator.token`, an agent MCP config or credentials into an
issue or log. The exact tool error, the agent's turn details and the doctor
output are enough to distinguish the common failures.

### A Claude worker says its Custode MCP tools are denied

An MCP-enabled routine starts Claude with its per-routine MCP config and an
exact `--allowed-tools` entry for every tool its role may use. An approved
continuation merges its worktree and elevated permission options over those
base arguments; moving into a worktree should not remove MCP access.

Claude Code evaluates deny rules before allow rules. A matching deny in host
settings blocks a tool even when Custode supplied it through
`--allowed-tools`, and a blocking `PreToolUse` hook also wins. Organization
managed settings outrank command-line, project and user settings and cannot
be relaxed in a lower-precedence file. In an interactive Claude session, use
`/permissions` to see the active rules and their source and `/status` to see
which settings sources loaded. Also inspect, as applicable:

- `~/.claude/settings.json` for user settings;
- `.claude/settings.json` in the repository for shared project settings;
- `.claude/settings.local.json` for machine-local project settings;
- the managed source named by `/status`: server-managed settings (cached in
  `~/.claude/remote-settings.json`, or under `CLAUDE_CONFIG_DIR` when set), an
  MDM profile, or a system `managed-settings.json` and its
  `managed-settings.d/` directory.

Current Claude Code accepts `mcp__custode__*` as an allow rule for every tool
on the named Custode server. An unscoped `mcp__*` allow glob is skipped with a
warning. Adding an allow rule cannot override a matching deny. Change an
organization rule through its administrator rather than trying to bypass it
locally. See Claude Code's
[permission rules](https://code.claude.com/docs/en/permissions) and
[settings precedence](https://code.claude.com/docs/en/settings) for the
current behavior.

An organization can set `allowManagedPermissionRulesOnly` in its managed
settings. Claude Code then keeps only the managed policy's allow rules and
drops every allow rule supplied as `--allowed-tools`, by a parent host, or in
any settings file, so no local or command-line allow rule applies and
Custode's allowlist has no effect. A headless turn cannot prompt, so every
tool without a managed allow rule is denied: Custode's MCP tools, other MCP
servers' tools, and even reads outside the working directory. The fix is a
managed allow rule such as `mcp__custode__*`, added by the organization's
administrator to the managed source Claude Code selects on that machine. See
[managed settings](https://code.claude.com/docs/en/managed-settings).

The same policy can set `permissions.disableBypassPermissionsMode` to
`"disable"`. That blocks the `bypass_permissions` permission mode, which
approved Claude continuations use by default, so approved work that needs it
cannot run on that machine.

`mix custode doctor` reads the server-managed settings cache and the system
managed settings files and prints a `warning:` line, without failing, for
either key. It does not read an MDM profile or the Windows registry; `/status`
names the managed source in force.

### `Invalid params` is not a permission denial

`Invalid params` means the MCP call reached argument validation. Record the
exact call before changing permissions. Self-scoped notebook calls accept the
authenticated identity by default; when diagnosing, make it explicit:

- `recall` with `agent_id: "<routine-id>"`;
- `inbox_list` or `todo_list` with `routine_id: "<routine-id>"`;
- repository reads with the routine's configured `repo`, for example
  `repo_list_prs` with `repo: "owner/name"`.

If the explicit call works, the connection and permission are sound; inspect
the tool schema and the original arguments. If it is still denied, preserve
the denial text and inspect Claude's effective permission sources above. If
it cannot connect or authenticate, run `mix custode doctor` and inspect the
turn's MCP startup error.

### SQLite reports `Database busy` after a turn finishes

Custode configures a five-second SQLite busy timeout for ordinary lock
contention. SQLite can still return `SQLITE_BUSY` immediately when waiting
would create a lock-upgrade deadlock. Custode's Oban engine retries the final
job-state update after 50, 100, 200 and 400 milliseconds. Those retries happen
after the provider turn and do not run the agent again.

No setup change is normally required. Repeated exhaustion means another
process is holding a long write transaction or two Custode instances are
using the same database. Stop the extra process and run `mix custode doctor`.

### Claude plan usage is blank or stale

Every ten minutes Custode reads Claude plan usage from Anthropic's OAuth usage
endpoint. It reads the Claude Code access token transiently from the macOS
Keychain item or `<CLAUDE_CONFIG_DIR>/.credentials.json`, sends it only to
`api.anthropic.com`, and never writes or logs it. Custode retains the resulting
usage windows in memory. It does not refresh or modify Claude credentials.

If the credential cannot be read, the endpoint rejects the request, or its
undocumented response changes, Custode uses the existing sealed Haiku probe.
Run `claude auth status` when the header remains blank. On macOS, a locked
Keychain can also prevent the background process from reading the item; using
Claude Code once after unlocking it normally restores the same credential
access Custode relies on.

## The dashboard

`http://localhost:4646`. Localhost only, no auth. No node or asset pipeline:
daisyUI 5 and Tailwind 4 come from CDN, the LiveView client from the hex
packages. Two themes, `paper` and `ink`, follow the OS preference; the header
toggles them ([guides/ui-hierarchy.md](guides/ui-hierarchy.md)).

| Page | What it is |
|---|---|
| `/` | **The console.** A rail of every subject grouped by what it needs (needs you, watching, working, scheduled, quiet), filterable by name, repository, tag or state. A subject pane with a message box that works in any state and tabs: attention, activity, work, notebook, panel, turns, config. An item pane with the evidence (failing checks, risk, the agent's context) and one control per thing you can do. |
| `/custode` | **Talking to custode**, `Cmd/Ctrl+K` from anywhere. A sentence box, custode's pending proposal as a plan with `do it` and `cancel`, its answers, and what it did while you were away. |
| `/metrics` | Spend, approval rates by agent, by gate class and risk, and writes observed outside an approval. |
| `/inbox`, `/repos`, `/workflows`, `/suggestions` | The needs-you queue, repository overviews, workflow runs, advisor suggestions. |
| `/fleet`, `/agents/:id` | Legacy bookmarks; redirect to the console and selected subject. |

Ranking is never done in a page. `Custode.Attention` is a pure resolver
([design/007-attention.md](design/007-attention.md)) and every surface draws
what it returns.

## Operating from a shell

`mix custode <command>` drives the running node over its MCP port:
`status`, `gates`, `approve`, `reject`, `asks`, `answer`, `dismiss`, `prompt`, `beat`,
`pause`, `resume`, `away`, `back`, `disown`, `reclaim`, `feed`, `spend`,
`drain`, `doctor`. From a git worktree, pass the token:
`CUSTODE_OPERATOR_TOKEN="$(cat <checkout>/tmp/operator.token)"`.

The [MCP client reference](docs/mcp-reference.md) documents every tool, prompt,
resource and resource template, including arguments, results, side effects and
access checks. A [JSON catalog](docs/mcp-reference.json) is available for clients.
Install the shared external-operator workflow for Claude Code, Codex, or both
with `mix custode.skill.install <claude|codex|all>`; the
[fresh-machine guide](guides/install.md#7-give-interactive-agents-the-operator-skill)
covers the host paths and connection boundary.

## How an agent works

- **Routine.** Id, role profile, repository, working directory, cron. Each
  beat is a fresh `claude` session: memory is the notebook, not the
  conversation.
- **Notebook and memory.** Journal, todos, key-value memories and a
  self-curated panel, all in SQLite and written only through MCP tools.
  `journal.md` and `TODO.md` in the workspace are rendered views. Writes are
  self-only. Journal reads are also self-only; todo, inbox and key-value
  memory reads are open.
- **Sensors.** Cheap cron jobs, never `claude`, that poll (CI status,
  contributors, feeds) and wake an agent with evidence only when something
  changed. Cheap sensor, expensive brain.
- **Gates.** An agent has no standing write permission. Anything
  write-shaped is a `request_permission` directive that parks the turn until
  the operator decides. A rejection's reason is what the agent learns from,
  so the form requires one and can mark it one-off. A gate records the
  **class** of action (`comment`, `file_issue`, `implement`, `pr_maintain`,
  `review`, `ready_pr`, `merge`, `roster`, `other`) and, for a gate on an
  existing pull request, the **risk** of the paths it changes.
- **Grants.** An approval is a live grant while its turn runs. The class
  bounds which repo write tools the turn may call and whether it gets a shell
  at all. `config :custode, gate_grant_mode:` is `:observe` by default
  (record what falls outside, refuse nothing) and `:enforce` refuses.
- **Asks.** A non-blocking question: the turn finishes, the answer arrives
  later as an inbox note. An ask may carry up to three suggested replies,
  answered in one click.
- **Cadence.** An agent that knows when there will next be something to do
  calls `set_next_beat`, within operator bounds. A retryable failure backs
  the next beat off; a rate limit with a future reset holds scheduled beats
  until it passes. An operator message, a sensor wake or `beat now` always
  runs at once.
- **Failures.** A failed turn is classified from typed fields. A repeated
  non-retryable one (not logged in, bad config) raises a needs-you signal
  whose headline is the fix.

Every MCP tool has an entry in `Custode.MCP.ToolPolicy`; a test fails, naming
the tool, if one ships without it.

### Journal reads over MCP

`journal_read` reads SQLite directly on both `/mcp` and `/mcp/memory`.
Routines and subagents can read only their own entries; the authenticated
operator can select any identity. The caretaker gets no extra journal scope.

| Optional argument | Contract |
|---|---|
| `routine_id` | String; defaults to the authenticated routine or subagent. The operator must select an identity. |
| `agent_id` | Alias for `routine_id`; a nonblank `routine_id` takes precedence. |
| `limit` | Integer, 1 through 100; defaults to 20. |
| `search` | Case-insensitive title/body search using the notebook query. Empty or omitted searches do not filter. |
| `live_only` | Boolean; defaults to true. False includes compacted entries until the janitor retires them. |

The result is `{"entries": [...]}`, newest first (timestamp, then entry id).
Each entry has `id`, nullable `title`, `body`, `inserted_at` (ISO 8601), and
`compacted_at` (ISO 8601 or null for live entries). No entries returns an empty
list. Invalid argument types are MCP invalid-params errors; an out-of-range
limit, unauthorized identity or missing operator selection is a tool error.

## Development

Work in a sibling git worktree (`../custode-work`), never in the checkout a
fleet is running from: the dev code reloader would hot-load the change.
CI runs five gates and so should you, before every push:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
```

Render a fixture-backed dashboard to a standalone HTML file without booting a
fleet. The console fixture opens the command menu so keyboard and search work
can be reviewed in either maintained theme:

```sh
MIX_ENV=test PREVIEW_PAGE=console PREVIEW_THEME=paper \
  PREVIEW_OUT=tmp/console-preview.html \
  mix test --include preview test/support/preview/dashboard_preview_test.exs

MIX_ENV=test PREVIEW_PAGE=custode PREVIEW_THEME=ink \
  PREVIEW_OUT=tmp/custode-preview.html \
  mix test --include preview test/support/preview/dashboard_preview_test.exs
```

Preview tests carry the `preview` tag and are excluded from the ordinary test
suite. Open the generated file in a browser; no server remains running.

Things that bite:

- The test database persists and is shared. Use `Custode.TestHelpers.uid/1`,
  never a fixed id. A test asserting on the whole fleet's attention calls
  `clear_attention!/0`. A new table goes in `test/test_helper.exs`'s truncate
  list.
- Two app-booting `mix` commands within 30 seconds collide on the instance
  guard (`instance_conflict`). Wait and rerun. Two worktrees test at once
  only with different `CUSTODE_TEST_MCP_PORT` values.
- Never run `mix run`, `iex -S mix` or `mix phx.server` from a worktree: it
  boots the dev app against the live ports.
- Migrations come from `mix ecto.gen.migration`, never hand-numbered.
- Before merging, `gh pr update-branch` and wait for CI on the updated
  branch. Two green PRs can turn `main` red together.

See [AGENTS.md](AGENTS.md) for the working agreement and
[ROADMAP.md](ROADMAP.md) for what is next.

## Design documents

| Doc | What it is |
|---|---|
| [000](design/000-the-operated-fleet.md) | The canonical model: operator, custode, specialists, sub-agents |
| [002](design/002-storage-doctrine.md) | Storage doctrine: records in the database, views in files |
| [007](design/007-attention.md) | The attention resolver and its signal kinds |
| [008](design/008-work-first-kernel.md), [009](design/009-tasks-not-agents.md) | The work-first kernel. **Frozen** (design/010): in the tree, not running |
| [010](design/010-back-to-the-dashboard.md) | The current plan, in rungs |
| [ui/](design/ui/2026-07-25-design-session/) | The design session the dashboard is built from |
