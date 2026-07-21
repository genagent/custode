# Roadmap

The "duh" list: obvious next features, tiered by consequence. Drawn from live
runs, 2026-07-20.

## Tier 1: before this touches anything real

- [ ] **Auth on both HTTP surfaces.** The dashboard (4646) and MCP (6161) are
      open localhost ports; a bearer token is an afternoon.
- [ ] **Per-agent MCP identity.** `routine_id` / `agent_id` are trusted tool
      parameters -- any tooled agent can write any journal or memory.
      Per-agent tokens embedded in per-agent MCP config files kill the class.
- [x] **Spend ledger + budgets.** Durable per-turn spend rows (in-process
      counters die on restart); daily caps that auto-pause a routine, resume
      as a human override. (`Custode.SpendLedger`)
- [ ] **Dead-man alerting.** The feed reports what happened, never what
      didn't. "Routine X hasn't completed a beat in N periods" -> notify.
- [ ] **MCP connection visibility.** One session in ~17 failed to connect to
      the MCP server (claude-side, transient); the only signal was the agent
      itself saying so. Surface tool-connection failures mechanically (e.g.
      detect a sweep summary reporting missing tools, or a per-turn
      tools-used telemetry check) instead of relying on the agent's honesty.

## Tier 2: durability holes the restart story doesn't cover

- [x] **Gated state doesn't survive restarts.** A pending approval/question
      died with the process. Now recorded in the `gates` table; on boot,
      unresolved gates become RESTART NOTICE inbox notes the next sweep
      re-evaluates. (`Custode.Gates`)
- [ ] **Sub-agents don't revive.** Routines self-heal via crontab-as-spec;
      sub-agents have no spec anywhere. A `sub_agents` table written by
      `start_agent` + revival on boot.
- [x] **Feed rotation.** `feed.jsonl` rotates to `.1` past `feed_max_bytes`
      (default 10MB). Proposed, and implemented in its worktree, by the
      custode-dev routine itself; human review fixed a function-in-guard
      compile error and merged.
- [ ] **Post-restart budget leak.** A restart clears an auto-pause, so an
      over-budget routine leaks one turn before re-pausing. A boot-time
      budget check (or a Tick-level guard) closes it.
- [x] **Worktree dev loop.** The `../oban_claude` path dep now honors an
      `OBAN_CLAUDE_PATH` env override, so a worktree checkout can point at
      the real sibling repo and run `mix compile`/`mix test` before
      reporting done. Proposed by the custode-dev routine itself (its second
      accepted change; the first shipped unverified for exactly this
      reason).
- [ ] **Elevation continuity across rail-stops.** An approved turn that
      rail-stops (per-turn budget) resumes its session on the next prompt
      WITHOUT the approved_args elevation -- the continuation cannot finish
      the approved work. Re-propose/re-approve works (proven live) but a
      sticky per-approval elevation until the action resolves would be
      cleaner.

## Tier 3: product "of course"s

- [ ] Dashboard: history drawer, memory viewer, full journal browser.
- [ ] Desktop notification deep-links to the blocked card.
- [ ] Mobile push: an ntfy.sh consumer of the same telemetry (~15 lines).
- [ ] Fleet-wide pause-all / resume-all.
- [ ] A second routine preset: the repo-gardener config map ("review
      yesterday's commits, update NOTES.md") that demonstrates the fleet
      vision for real.
- [ ] Boot preflight: run oban_claude's doctor check at startup and warn
      loudly if claude is missing or unauthenticated.
- [ ] Idle sub-agent TTL/GC.
- [ ] Cron timezone config (Oban supports it).
- [ ] Structured one-shot reports: a child's structured output riding the
      report note, so sweeps can file results mechanically instead of
      re-reading prose.

## Standing architectural notes

- Extraction trigger for the agent layer (oban_claude spike -> its own hex
  package): the first HARD dep oban_claude shouldn't carry. Optional deps
  don't count.
- The dashboard's eventual form is a mountable component (Oban.Web-style);
  the LiveViews stay thin over the facade to keep that extraction mechanical.
