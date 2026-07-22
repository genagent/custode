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

With `CUSTODE_HOME` set, the database, workspace notebooks, agent tokens,
feed, and the roster all root under that one directory. Unset, everything
lives beside the code (the dev-loop default).

## 3. Preflight

```sh
mix custode doctor
```

Six checks, no paid calls, non-zero exit on any failure: the claude binary
and its auth, gh and its auth, the configured timezone resolving, the home
being writable, and the roster parsing. Fix what it names and run it again.
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

## Uninstall

Stop the server, delete `$CUSTODE_HOME`, delete the checkout. The worked
repositories were never custode's to hold -- your checkouts stay yours.
