# 004: Telemetry, windows, and the two grades of advisor

Status: proposed (operator-drafted 2026-07-22, from the operator's framing:
"really good telemetry would let us monitor everything and periodically
look at a window of activity and adjust... I don't want too many meta
agents running... or maybe these are all advisors.")

The last line is the design. This doc takes it seriously: every
watch-the-fleet-and-suggest concern IS an advisor, advisors come in two
grades, and no new standing agents exist anywhere in the loop.

## D1. Telemetry is the only substrate

Everything that adjusts reads the same recorded stream; nothing keeps
bespoke counters. Today's emitters: oban_claude run start/stop/exception,
agent transitions, sensor status lines, gates, spend rows, scheduler
fires. Their db projections (feed, spend, gates, sub_agents) are the
queryable form -- the storage doctrine's records (design 002), already
timezone-honest (#164).

The rule going forward: **a mechanism ships with its telemetry or it does
not ship.** New verbs, new schedulers, new reconcilers -- each emits from
birth. A coverage-audit slice below closes today's gaps (drain progress,
advisor runs themselves, inbox flows).

## D2. The Window Digest: one builder, many readers

A deterministic `Custode.Digest` builds a compact, typed summary of any
window: spend by agent and model, sweeps and yields, gate latencies,
failures and their kinds, standing advisor suggestions, notable anomalies
(rail hits, turn-failure streaks, silent sensors). Pure queries, zero
tokens, renders to both a map (for code) and markdown (for prompts and
humans).

One builder, at least three readers:

  * judgment advisors (D3) -- the digest IS their observation
  * the presence flow (#141 slice 3) -- the "while you were away" digest
    on operator return
  * the human -- the morning-report pattern, and eventually a dashboard
    panel (#100's agent-authored panels could render it)

The digest is the bridge that keeps LLM eyes OFF raw telemetry: a
judgment call reads two hundred lines of curated summary, never two
hundred thousand events.

## D3. Two grades of advisor, one behaviour

`Custode.Advisor` (shipped, #154/#188) stays the only chassis. Grades:

  * **:deterministic** -- observe/suggest are pure Elixir (Cadence,
    Model, Budget). Zero tokens, the default, the bar every advisor must
    justify leaving.
  * **:judgment** -- observe/0 builds the Digest for its window; suggest/1
    makes ONE bounded LLM call (small model, hard token cap, json-schema
    output of suggestion maps) over the digest and returns the same typed
    suggestions. Still suggest-only, still cooldown-keyed, still on the
    sensor lane as a one-shot Oban job. NOT an agent: no gen_statem, no
    session, no tools, no standing anything. It is a sensor that thinks
    for one bounded moment.

The first judgment advisor is **Advisors.Retro** (weekly): reads the
7-day digest and suggests what no single-metric rule sees -- "these two
routines duplicate each other's coverage", "this repo's failures cluster
after that dependency bump", "the reviewer's queue pattern suggests
raising its cadence on weekdays only". Its suggestions land exactly like
the trio's.

## D4. Advisors become roster config, not code wiring

The hardcoded crontab entries give way to config, making every advisor
toggleable (the operator's optionally-turned-off requirement) and the
roster file the truth here too (design 003's custode.toml carries it):

    [advisors]
    cadence = "@daily"
    model = "@daily"
    budget = "@daily"
    retro = "@weekly"       # judgment-grade; omit to disable
    # any = false            # disabled explicitly

Loader conversion follows the sensor pattern; unknown advisor names fail
the boot loudly. Defaults preserve today's behavior.

## D5. The caretaker keeps operations; judgment-about-the-fleet moves out

The caretaker's job stays real-time operations: gates going stale, stuck
siblings, silent sensors, budget pauses -- the duties that need an
ADDRESSABLE agent because they act (beat, escalate, ask) rather than
suggest. Retrospection leaves its orders entirely: the weekly look-back
is Advisors.Retro's, and the caretaker's sweep stops being the place
where fleet-tuning thoughts accumulate. One meta tile, unchanged; fewer
jobs on it, not more.

## Non-goals

- No advisor ever writes config; the operator (through #174's write-back
  when it lands) stays the actuator. Judgment grade does not change this.
- No standing meta-agents beyond the caretaker. A judgment advisor that
  wants tools, sessions, or multi-turn work is asking to be a routine;
  make the case explicitly or stay a bounded one-shot.
- No raw-telemetry prompting. If a judgment advisor's digest is
  insufficient, extend the Digest builder -- deterministically.

## Slices

1. **feat: Custode.Digest** -- the builder + markdown/map renders + tests
   (deterministic; immediately reusable by the morning report by hand).
2. **feat: advisor roster config** (D4) -- config-driven advisor entries
   through the Loader pattern, defaults matching today.
3. **feat: judgment grade + Advisors.Retro** -- the one-bounded-call
   contract (json-schema suggestions, token cap, small model), weekly.
4. **chore: telemetry coverage audit** (D1) -- emit-from-birth rule
   documented, gaps closed (drain, advisor runs, inbox flows).
5. **#141 slice 3 rides D2** -- digest-on-return becomes a Digest call.
