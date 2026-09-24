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
