# Custode 0.1.0: quickstart and demonstration

One path from a fresh checkout to a reviewable pull request produced by one
scheduled agent, operated from the dashboard and from MCP, and surviving a
restart. It takes about thirty minutes plus the agent's own turns. For a
second machine, phone access and uninstalling, see
[install.md](install.md).

## What 0.1.0 is

- A single Elixir node you run on your own machine. It keeps a roster of
  **routines**, usually one per GitHub repository. A routine is a persistent
  identity: its roster entry, notebook, gates and feed outlive any single
  run. The work itself runs as turns in `claude` or `codex` provider
  sessions: each scheduled beat starts a fresh session, and operator
  messages continue a resumable conversation (see
  [Known limitations](#known-limitations)).
- One human operator. Agents have no standing write permission: anything
  write-shaped is a **gate** that waits for your approval. Nothing merges
  without a human.
- Three surfaces over the same operations: the LiveView dashboard
  (`http://localhost:4646`), the `mix custode` CLI, and an authenticated MCP
  endpoint (`http://127.0.0.1:6161/mcp`).
- Durable state in one directory (`CUSTODE_HOME`): a SQLite database, the
  roster file, notebooks and agent-owned clones.

It is not a hosted service, a multi-user system or a CI replacement. Future
work is in [ROADMAP.md](../ROADMAP.md) and
[design/010](../design/010-back-to-the-dashboard.md).

## 1. Prerequisites

- Elixir `~> 1.20` on OTP 29.
- `gh`, authenticated (`gh auth status`). Custode clones repositories and
  reads pull requests through it.
- At least one provider CLI, installed and logged in with its own stored
  credentials (Custode does not use API keys):
  - **Claude**: the `claude` CLI, logged in (`claude auth status`).
  - **Codex**: the `codex` CLI, logged in (`codex login`).
- Read access to the private `joshrotenberg/mcp_ex` repository. `mix deps.get`
  fetches it over SSH (`git@github.com:joshrotenberg/mcp_ex.git`), so your SSH
  key must be able to read it. Without SSH access, set `MCP_EX_PATH` to a
  local checkout of that repository (the repository root, not a
  subdirectory) at the revision pinned in `mix.exs` before fetching.
- A GitHub repository you are willing to let an agent open a draft pull
  request against. A small sandbox repository is best for the demonstration.

`mix custode doctor` checks the `claude` CLI and not `codex`. Section 3 gives
the preflight for each provider setup.

## 2. Fresh checkout and home

```sh
git clone https://github.com/genagent/custode
cd custode
export CUSTODE_HOME=~/.custode-demo    # every piece of runtime state lands here
mix deps.get
```

Export `CUSTODE_HOME` in every shell you use below, including the ones that
run `mix custode`. The CLI finds the operator token through it.

## 3. Migrate, preflight, boot

```sh
mix ecto.migrate      # creates $CUSTODE_HOME/custode.db; boot also migrates
mix custode doctor    # no paid calls; non-zero exit on any failure
mix phx.server        # dashboard :4646, MCP 127.0.0.1:6161
```

`mix custode doctor` checks the `claude` binary and its login, `gh` and its
login, the configured timezone, that the home is writable, that the roster
parses, migration versions and pending count, and whether the checkout is
behind its upstream. It also reads the organization's managed Claude Code
settings and warns, without failing, when they drop Custode's MCP allowlist
or disable bypass permissions mode. It has no Codex check. Read its result by
provider setup:

- **Claude, or both providers**: every check must pass. With both, also run
  the Codex check below.
- **Codex only**: the two Claude checks (`claude binary + version`,
  `claude authentication`) fail and the command exits non-zero. Confirm that
  they are the only failures, then check Codex directly:

  ```sh
  mix custode doctor --json   # every check except the two claude ones must be "ok": true
  codex --version
  codex login status          # e.g. "Logged in using ChatGPT"
  ```

  Choose `codex` as the provider when you create the agent in section 4.

  The node boots, but it runs the same Claude check at boot and, when it
  fails, withholds the `:ticks` queue: the log says `claude doctor failed;
  ticks withheld`, and the console shows **no agent can run: the boot doctor
  failed**. That queue carries scheduled beats and inbox wake-ups, so on a
  Codex-only host the agent does not run on its schedule. Work you send it
  from the console or with `prompt_agent`, answers and gate decisions do not
  use that queue, so sections 5 to 8 still apply. To get scheduled beats,
  install the `claude` CLI and log in, then restart.

With no roster the remaining checks pass and the boot log says:

```
custode: no routines.toml found, the fleet is empty (cp routines.example.toml routines.toml, or add an agent from /console)
```

Schedules and daily spend rails roll over in the configured timezone,
`America/Los_Angeles` by default. Set `config :custode, timezone: "..."`
before the first boot if yours differs.

A second boot against the same home refuses while the first is alive.

## 4. Create one agent from the empty fleet

Open `http://localhost:4646`. An empty fleet opens **choose your agent**
("No agents on this machine yet."). The fleet caretaker is marked
**recommended**; it enables the `/custode` conversation surface, but this
walkthrough uses one specialist so that a single agent does the whole task.

1. Choose **Specialist** ("Uses a high-capacity model for difficult
   persistent work.").
2. Fill in the **new agent** form:
   - **id**: `demo` (the default is `specialist`).
   - **provider**: `claude` or `codex`. The specialist profile resolves to
     `opus` on Claude and `gpt-5.6-sol` on Codex.
   - **cadence**: pick a preset such as **Weekdays** (09:00, Monday to
     Friday) or **Daily**. **Profile default** is daily for a specialist. The
     timezone is shown under the field. Only **Custom** asks for cron syntax.
   - **repository**: `owner/name` of your sandbox repository. For a
     specialist the repository is optional; entering one shows the checkout
     choice.
   - **checkout on this Custode host**: keep **managed clone**
     (recommended).
   - **standing prompt** (optional): what this agent owns, for example "Keep
     owner/name's documentation accurate."
3. Review the two previews before creating: **appended to the roster** is
   the exact TOML that will be written, with a note such as "Clone owner/name
   into /…/checkouts/demo on the Custode host before adding the agent.", and
   **resolved agent** shows provider, model, cadence and rails.
4. Press **create**. Custode clones the repository through `gh` into
   `$CUSTODE_HOME/checkouts/demo`, appends the routine to
   `$CUSTODE_HOME/routines.toml` and selects the new subject: "demo added:
   live now, scheduled at its next cron minute". No restart and no hand
   editing.

The agent works in its own clone under `$CUSTODE_HOME/checkouts/`, never in
the checkout running Custode. An approved Claude continuation runs in an
isolated git worktree inside that clone.

With no caretaker, the console shows a caretaker setup notice. It is safe to
leave for this walkthrough.

## 5. Submit one bounded task

The selected subject has a message box in every state. A new routine is
**offline** ("offline -- the next beat starts it"), so the button reads
**start + send**. Send something small and checkable, for example:

> Add a short "Running the tests" section to README.md in owner/name. Propose
> it as one gated change: branch docs/readme-tests, one commit, one draft PR.
> Do not merge.

The button label follows the agent's state: **send**, **queue** while a turn
is running, **answer** while it is waiting on you, **resume + send** when
paused.

## 6. Observe, answer and approve

- **Rail.** Subjects are grouped **needs you**, **watching**, **working**,
  **scheduled** and **quiet**. While the turn runs the subject shows a
  **working** badge with elapsed time.
- **Tabs.** **attention** (what it needs and what it last said),
  **activity** (the durable feed), **work** (the repository and its open
  pull requests), **notebook** (journal, todos, memories), **panel**,
  **turns** (the raw process log since this boot) and **config**.
- **A question.** An agent may ask without stopping ("asked you a
  question"). Answer in the item pane (**answer**, or one of the suggested
  replies under **or just say**), or **dismiss** it.
- **A gate.** Before it writes, the agent stops with "wants your approval",
  usually with a class such as `(implement)`. The item pane shows the
  evidence, **approve** and **reject**. A rejection needs a reason ("why?
  the agent reads this, and may make it a rule"); tick **one-off** if it
  should not become a standing rule.

Approve the gate. The approved continuation implements the change, pushes
the branch and opens the pull request. Custode's `repo_open_pr` tool always
opens a **draft**.

Inspect the outcome in the **activity** tab (turns, the gate and its
decision, repository writes), the **notebook** tab (the journal entry the
agent wrote), the **work** tab and GitHub.

## 7. The same operations over MCP

The CLI is an MCP client of the running node, so these are the same
operations the UI performs:

```sh
mix custode status                     # list_routines
mix custode attention                  # list_attention
mix custode prompt demo "Status of the README change?"   # prompt_agent
mix custode asks                       # list_asks
mix custode answer <ask-id> "yes"      # answer_ask
mix custode gates                      # list_gates
mix custode approve demo <action-id>   # approve_action
mix custode feed                       # feed_tail
```

Any other MCP client can connect to `http://127.0.0.1:6161/mcp` (Streamable
HTTP, loopback only) with the operator token:

```sh
export CUSTODE_OPERATOR_TOKEN="$(cat "$CUSTODE_HOME/tmp/operator.token")"
```

Send `Authorization: Bearer $CUSTODE_OPERATOR_TOKEN`, `initialize`, then
`notifications/initialized`, then `tools/call`. The transport is stateless;
the server returns no session id. The token file is rewritten on every boot,
so read it again after a restart. Keep it out of logs and issues.

| Step | Tool and arguments |
|---|---|
| Discovery | `tools/list`; `list_routines` |
| Submit a task | `prompt_agent` with `agent_id: "demo"`, `prompt: "..."`, optionally `idempotency_key`; returns a receipt with `message_id` |
| Wait | `await_agent` with `agent_id: "demo"` and that `message_id` (default 60 s, max 180 s) |
| Status and conversation | `agent_status` with `agent_id: "demo"` |
| Attention | `list_attention`, optionally `group: "needs_you"` |
| Decide | `answer_ask`, `approve_action`, `reject_action` |

With `message_id`, `await_agent` waits for that one message to reach
`waiting_for_input`, `waiting_for_approval`, `completed`, `failed` or
`refused`, and returns its durable receipt. A message parked on a gate or a
question has not finished its task. Retrying `prompt_agent` with the same
`idempotency_key` and prompt returns the existing receipt instead of sending
the work twice. Without `message_id`, `await_agent` falls back to waiting for
the agent to settle, and its last result may belong to an earlier turn. The
UI reads the same records: a gate approved over MCP disappears from the
console, and a message sent from the console appears in `agent_status`.
Arguments, results and access rules for every tool are in the
[MCP client reference](../docs/mcp-reference.md).

## 8. Drain, restart, recover

```sh
mix custode drain      # stop admitting work, let executing turns finish, stop
mix custode doctor     # on a Codex-only host, read it as in section 3
mix phx.server
```

Decide open gates before draining where you can. A gate still open at
shutdown is not lost: on boot it becomes a restart notice in the agent's
inbox, and the agent raises it again on its next turn if it still applies.

What comes back, all under `$CUSTODE_HOME`:

| Where | What |
|---|---|
| `routines.toml` | the roster, including `demo` |
| `checkouts/demo/` | the agent-owned clone and its branches |
| `custode.db` | the feed, gates with outcome and decider, asks and answers, notebooks, spend, and conversation arcs |
| `feed.jsonl` | an append-only mirror of the feed |
| `workspaces/demo/` | the inbox, rendered `journal.md` / `TODO.md`, and `HANDOFF.md`, the bounded context file each scheduled turn reads |
| `tmp/` | per-boot operator and agent tokens and MCP configs (regenerated) |

After the restart the subject is offline until its next beat or message. The
**activity** and **notebook** tabs, the gate history and the pull request
are unchanged. The subject header names the conversation as
`operator arc <arc-id> · <decision>/<reason> · session ready`, and
`agent_status` returns the same arc under `conversation.current`. The next
operator message resumes that provider session when the provider, host,
workspace and configuration still match; if the provider can no longer open
it, Custode records `fresh_fallback` and starts fresh with a recovery note. The **turns** tab is
empty until the agent runs again, because it shows only this boot's process
log.

## Known limitations

- One node, one operator, localhost. There is no application-level
  authentication; see [install.md](install.md) before exposing the
  dashboard.
- `mcp_ex` is a private Git dependency; see prerequisites.
- `mix custode doctor` does not check the Codex CLI, and on a Codex-only host
  it exits non-zero on its Claude checks. The boot check behind it also
  withholds scheduled beats on such a host; see section 3.
- Every turn is a real provider call against your plan. Rails pause an agent
  at its daily limit; the specialist profile's defaults are high (25 USD per
  turn, 100 USD per day), editable in the **config** tab.
- Scheduled beats always start a fresh provider session; only the operator
  conversation resumes. Important results must land in
  the notebook, an issue or a pull request, not only in a transcript.
- Codex continuations are not moved into a separate worktree; they run in the
  agent's owned clone.
- The work kernel (design/008) is frozen and not part of this path.
