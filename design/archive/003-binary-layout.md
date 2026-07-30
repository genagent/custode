# 003: The binary layout — XDG directories and TOML all the way down

Status: proposed (operator-drafted 2026-07-22, extending design 001 to the
shippable-binary future; the operator's framing: "in a source run we have
the full elixir project layout, especially config. In a binary run we need
a directory for stuff, XDG style, and probably TOML for all configs so we
don't rely on exs.")

Design 001 made the ROSTER a data file and rooted runtime state under
`$CUSTODE_HOME`. This doc specs the rest of the distance to a binary: where
everything lives when there is no project directory, and what config
remains exs-shaped when Mix is gone.

## D1. Two modes, decided by the artifact, not a heuristic

* **Source mode** (running from a checkout via `mix`): everything as today
  — cwd-rooted, `config.exs` as the config surface, `routines.toml`
  optional. Nothing in this doc changes the dev loop.
* **Binary mode** (a release/burrito artifact): XDG directories by
  default, TOML as the only operator-facing config. The MODE IS THE
  ARTIFACT: a release sets it at build time; no sniffing for mix.exs at
  runtime, no "am I installed?" guessing.

`$CUSTODE_HOME` remains the universal override in both modes: set it and
everything lives under that one directory (the work-laptop single-unit
install design 001 shipped). XDG is the default for binary mode when it is
NOT set.

## D2. The XDG split

Config is what the operator edits; data is what the fleet accumulates;
cache is what can burn. They have different backup, sync, and deletion
stories, so they split per the base-dir spec:

| What                                   | XDG home                          |
|----------------------------------------|-----------------------------------|
| `custode.toml`, `routines.toml`, prompt overrides (D4) | `$XDG_CONFIG_HOME/custode/` |
| `custode.db`, `workspaces/` notebooks, feed mirror     | `$XDG_DATA_HOME/custode/`   |
| worktrees, MCP config files, operator token            | `$XDG_RUNTIME_DIR/custode/` (fallback: cache) |
| dialyzer PLTs, gh response caches (future)             | `$XDG_CACHE_HOME/custode/`  |

The tokens/MCP-config placement is load-bearing: they are BOOT-SCOPED by
design (#107 — losing them on restart is the point), which is exactly what
`XDG_RUNTIME_DIR` means. Putting them in data would invite the ghost-server
class back through stale-file confusion.

Implementation is one module: `Custode.Home` grows `config_dir/0`,
`data_dir/0`, `runtime_dir/0`, `cache_dir/0`, each resolving
CUSTODE_HOME-collapse first, then mode. Every current `Home.resolve/1`
caller migrates to the specific dir. Nothing else in the codebase learns
about XDG.

## D3. `custode.toml` — the operator config beyond the roster

The roster (`routines.toml`) stays its own file: it changes per-machine and
per-week, write-back appends to it, and it already works. `custode.toml`
carries the rest of what an operator tunes, mirroring today's config keys:

```toml
[fleet]
timezone = "America/Los_Angeles"
model = "sonnet"
max_budget_usd = 1.0
daily_budget_usd = 5.0

[server]
dashboard_port = 4646
mcp_port = 6161
# dashboard_auth REQUIRED before any non-loopback exposure (#65)
# [server.dashboard_auth]
# username = "..."
# password = "..."

[ambient]
orders = [{ repo = "genagent/custode" }]

[janitor]
feed_days = 90

[profiles.backlog_worker]
# same keys as the exs profiles map; loader converts identically
cron = "@daily"
role = "backlog_worker"
# ...

[[policies]]
id = "conventional_commits"
applies = [{ tag = "repo" }]
text = "..."
```

Loading follows the proven Loader pattern (design 001 D3): parse in
`runtime.exs` (releases evaluate it without Mix), convert through explicit
key whitelists to the exact shapes the exs config produces, apply via
`config/2`, unknown keys fail the boot loudly. File wins outright over exs
for any section it carries; sections it omits fall back — per-SECTION
resolution rather than D1's whole-file rule, because "tune one budget
without copying every policy" is the actual operator story here.

What never moves to TOML: endpoint/repo adapter plumbing, the supervision
tree, anything that must exist before `runtime.exs` evaluates. That is
code, not config, and pretending otherwise is how config files grow a
programming language.

## D4. Prompts ship in priv/, override in config

The #38 vocabulary holds: charter and role bodies are the fleet's code.
In binary mode they ship inside the release as `priv/prompts/*.md`, read
through one accessor. The config dir may carry
`prompts/<role>.md` overrides — the operator's escape hatch — with a boot
log line naming any override in effect (the ambient-orders pickup-journal
pattern, applied to the fleet's own brain). `system_prompt_file` roster
references resolve against the config dir in binary mode.

## D5. What this does NOT change

* No new config format for source mode; exs stays the dev surface.
* No hot-swapping `custode.toml` (roster reload is live via write-back;
  fleet-level config changes take a drain+boot, which #132/#145 made
  cheap). The cadence advisor's accepted suggestions go through roster
  write-back, untouched by this doc.
* No secrets in TOML beyond dashboard_auth: claude and gh auth stay with
  their own CLIs (doctor #168 checks them), and nothing custode-side
  stores API keys.

## Slices

1. **feat: Home grows the four dirs** with CUSTODE_HOME collapse and
   mode selection (source→cwd for all four; binary→XDG); migrate current
   callers to specific dirs. Testable now, binary-ready later.
2. **feat: custode.toml loader** for `[fleet]`/`[server]`/`[ambient]`/
   `[janitor]` (the scalar sections), per-section wins-outright.
3. **feat: profiles and policies from custode.toml** (the structured
   sections, converting to the exs shapes).
4. **feat: prompts to priv/ + config-dir overrides.**
5. **chore: the release/burrito build target** wiring MODE=binary, plus
   doctor gaining a "mode + directories" report line.

Slices 1–2 are workable now and independently useful on the work laptop
(single CUSTODE_HOME still collapses everything, so the XDG split is
opt-in by absence). 3–5 order freely after.
