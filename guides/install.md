# Installing custode on a fresh machine

The whole install is: prerequisites, one environment variable, a preflight,
a boot, and then telling the fleet what to watch. Everything the fleet
accumulates lives under one directory you can back up or delete as a unit.

## 1. Prerequisites

- Elixir ~> 1.20 / OTP 29
- The `claude` CLI, logged in (`claude login`) -- custode shells out to it;
  its auth is its own, not an API key
- The `gh` CLI, authenticated (`gh auth status`) -- repo panels, worker
  reads, and the caretaker's access checks ride it
- Local checkouts of the repositories you want worked, anywhere you like
  (absolute paths go in the roster)

## 2. Clone and configure the home

```sh
git clone https://github.com/genagent/custode
cd custode && mix deps.get

export CUSTODE_HOME=~/.custode   # all runtime state lives here
```

The normal install resolves both agent wrappers from Hex and needs no sibling
repositories. Wrapper contributors can opt into a source checkout before
fetching dependencies:

```sh
export OBAN_CLAUDE_PATH=/path/to/oban_claude
export OBAN_CODEX_PATH=/path/to/oban_codex
mix deps.get
```

Set either variable on its own when changing only one wrapper.

With `CUSTODE_HOME` set, the database, workspace notebooks, agent tokens,
feed, and the roster all root under that one directory. Unset, everything
lives beside the code (the dev-loop default).

## 3. Preflight

```sh
mix custode doctor
```

No paid calls, non-zero exit on any failure: the claude binary and its auth,
gh and its auth, the configured timezone resolving, the home being writable,
the roster parsing, migration versions, and the checkout against its
upstream. Two more lines read the organization's managed Claude Code settings
and say `warning:` without failing when they drop Custode's MCP allowlist or
disable bypass permissions mode; the README's troubleshooting section says
what to ask the administrator for. Fix what it names and run it again.
Set your timezone first if it is not the default -- schedules AND daily
spend rails both roll on it:

```elixir
# config/config.exs
config :custode, timezone: "America/Los_Angeles"
```

## 4. First boot

```sh
mix run --no-halt        # or: caffeinate -i mix run --no-halt on a laptop
```

The dashboard is at `http://localhost:4646` (loopback only; set
`config :custode, :dashboard_auth` before exposing it any further). The
instance heartbeat guarantees a second boot against the same home refuses
rather than double-running; `CUSTODE_TAKEOVER=1` is the escape hatch for a
wedged predecessor.

## 5. Tell the fleet what to watch

Three equivalent paths, all funneling through the same gated write-back:

- **The form**: "new agent" on the fleet page -- five fields, a profile
  dropdown, and a live preview of the exact TOML that will land.
- **The conversation**: prompt the `custode` agent -- "watch owner/repo
  like the others". It checks your access, gates the clone to the
  convention path, and proposes the add with the literal roster entry in
  the gate card; you click approve.
- **The file**: edit `$CUSTODE_HOME/routines.toml` yourself. It is the
  whole roster, and it wins outright over anything in `config.exs`.

However added, a routine is beatable immediately and scheduled at its next
cron minute -- no restart. Budgets default sanely; every write an agent
wants goes through an approval gate; nothing merges without a human.

## 6. Operating

- `mix custode status | gates | approve | reject | beat | feed | spend`
  -- the operator CLI (it talks to the running server)
- `mix custode drain` -- the graceful stop: pauses the queues, waits out
  executing turns, and the server stops itself; then boot again
- The feed and each agent's page carry the story; gates are one click

## Updating

Run updates from the checkout that hosts the fleet. Drain Custode and wait for
the process to exit before changing that checkout. Then:

```sh
git pull --ff-only
mix deps.get
mix custode doctor
mix ecto.migrate
mix custode doctor
mix custode.skill.install all
mix run --no-halt
```

Review the release's operating note and pending migrations before running the
commands. Take a recoverable backup of `CUSTODE_HOME` when schema changes
warrant one. The skill installer prints a `--force` command for a stale or
modified package; inspect the installed files before choosing to run it. Select
`claude` or `codex` instead of `all` when only one host is configured. After
Custode restarts, reload `CUSTODE_OPERATOR_TOKEN` from the new token file and
restart or reconnect each provider session. The installed operator skill's
lifecycle reference carries the full drain, failure and recovery procedure.

### Upgrading from v0.2.2 to v0.3.0

This remains a source-installed GitHub release, with no Hex package or binary
artifact. Use the update procedure above with the v0.3.0 source. The release
adds one migration, `20261004034345_create_peer_messages.exs`, for durable
peer envelopes and delivery state. Back up `CUSTODE_HOME` before migrating.
If upgrading from an older release, review every pending migration rather
than assuming this is the only one.

The caretaker prompt now describes the continuing project-manager workflow.
Its `project_progress` read can inspect full direct operator exchanges for
configured projects. Peer message bodies remain participant-scoped for agent
identities; the human operator retains fleet-wide visibility. The manager
cannot approve a sibling's gate or answer an operator question on the human's
behalf. Restart Custode after the update so the prompt, MCP capabilities, and
provider execution path are loaded.

The release uses published ObanClaude 0.10.0, ObanCodex 0.7.0, Claude wrapper
0.15.1, Codex wrapper 0.6.0, and Forcola 0.6.0. Normal installations need no
local wrapper overrides. Early session observations help compatible later
turns resume after interruption; they do not prove work completed. Workflow
failure display preserves recorded evidence, while safe retry remains deferred
under #750.

## 7. Give interactive agents the operator skill

Claude Code and Codex can use the same thin operating contract when they
connect to Custode as the human operator. Install it for either host or both:

```sh
mix custode.skill.install claude
mix custode.skill.install codex
mix custode.skill.install all
```

The command writes the complete `custode-operator` package under each host's
normal skills directory, including its focused lifecycle, troubleshooting and
self-maintenance references. It respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
and refuses to replace locally changed managed files unless you pass `--force`.
It preserves unrelated files in the skill directory.

The package is explicit-only in both hosts so an ordinary Custode routine does
not select the operator workflow from the global skill directory. Invoke it
with `/custode-operator` in Claude Code or `$custode-operator` in Codex. Its
first action, `operator_bootstrap`, also requires a verified human operator
identity; routine and sub-agent identities cannot discover or call it. Restart
the host after installing or updating the package so it discovers the current
content.

Routine launch also enforces the boundary. Claude routines and sub-agents load
project and local settings without the user setting source, which retains the
repository's `CLAUDE.md`, agents, and skills while excluding every global user
skill, hook, agent, and setting. Claude authentication remains available.
Codex routines keep other user and repository skills but disable the exact
installed `custode-operator` path under strict configuration. Separately,
routine and sub-agent server identities cannot discover or call
`operator_bootstrap`.

`mix custode doctor` reports each host's package as current, missing, stale or
modified and prints the matching install command. Stale and modified packages
require `--force`; inspect what is installed before replacing it. Skill
findings are warnings because the package is optional for running the fleet.

The skill does not configure MCP or copy a token. In the shell that will start
Claude Code or Codex, read the current token and add the default main endpoint:

```sh
export CUSTODE_OPERATOR_TOKEN="$(cat "$CUSTODE_HOME/tmp/operator.token")"

claude mcp add --transport http --scope user custode \
  http://127.0.0.1:6161/mcp \
  --header 'Authorization: Bearer ${CUSTODE_OPERATOR_TOKEN}'

codex mcp add custode \
  --url http://127.0.0.1:6161/mcp \
  --bearer-token-env-var CUSTODE_OPERATOR_TOKEN
```

Both commands save only the environment variable name, not its value. The
single quotes around Claude's header are required; double quotes would expand
and save the secret. The host must inherit `CUSTODE_OPERATOR_TOKEN`; read it
again and restart the host after every Custode restart because the token file
is rewritten on boot. The loopback endpoint is available only on the Custode
host. Use the configured MCP port instead of `6161` when it differs, and
verify from the same shell with `claude mcp list` or `codex mcp list`.

A fresh operator session starts with `operator_bootstrap`, uses live tool
discovery for schemas, sends correlated durable messages, and relays gates and
asks to the human instead of deciding them itself. Its lazy references cover a
safe local restart, symptom-led diagnosis and routing changes to the routine
that owns `genagent/custode`. If Claude reports that the server is connected
but its tools are denied, follow the
[managed-policy troubleshooting path](../README.md#a-claude-worker-says-its-custode-mcp-tools-are-denied);
an organization policy cannot be relaxed in local configuration. The
[MCP client reference](../docs/mcp-reference.md) remains the maintained catalog
of arguments, effects, and access checks.

## From the phone (optional)

The dashboard can ride your tailnet without leaving loopback -- tailscale
proxies it, device membership is the auth boundary:

```sh
mix phx.gen.secret                      # once; the demo key never leaves localhost
export CUSTODE_SECRET_KEY_BASE=<that>
export CUSTODE_PUBLIC_HOST=<machine>.<tailnet>.ts.net
mix run --no-halt
tailscale serve --bg http://127.0.0.1:4646
```

The server refuses to boot with `CUSTODE_PUBLIC_HOST` set but no real
secret key. Gate approvals, prompts, and the feed all work from the phone;
ntfy deep links point at the ts.net address automatically. Do NOT use
`tailscale funnel` (public internet) -- there is no app-level auth yet.

## Uninstall

Stop the server, delete `$CUSTODE_HOME`, delete the checkout. The worked
repositories were never custode's to hold -- your checkouts stay yours.
If you installed the operator skill, also remove its `custode-operator`
directory under `${CLAUDE_CONFIG_DIR:-~/.claude}/skills` and
`${CODEX_HOME:-~/.codex}/skills`, then remove the saved MCP registrations:

```sh
claude mcp remove custode --scope user
codex mcp remove custode
```
