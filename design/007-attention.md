# 007: Attention -- one derived signal per agent

Status: implemented in #296 (the resolver) and #298 (the page), in review
as PR #297 as of 2026-07-25. Prompted by an external design review of the
dashboard, whose wider proposals this doc also dispositions (part two).

## The gap

The fleet page answers *what exists*. The operator's question is *what
needs me*. Those were the same page, drawn at the same weight, and the
sort key lived in a template:

```elixir
{if(needs_attention?(tile.status), do: 0, else: 1),
 if(tile.state == :ended, do: 1, else: 0), activity_key(tile.last_activity), id}
```

Three consequences, all visible on the running fleet the morning this was
written. Attention was **binary**, so everything inside the needs-you
bucket fell back to recency. `:paused` counted as attention, putting a
deliberate operator act in the same bucket as an open gate. And because
the logic was a sort key rather than a value, every new surface -- inbox,
digest, CLI, the rail chip -- re-derived it slightly differently.

The fleet at 17 agents, six of them wanting a human, was drawn:

| drawn | agent | kind | open |
| --- | --- | --- | --- |
| 1 | codex_wrapper_ex | approval | 4m |
| 2 | redisctl | approval | 48m |
| 3 | tower-mcp | approval | 30m |
| 4 | git-spawn | approval | 30m |
| 5 | redis-tower | **question** | 30m |
| 6 | adrs | **question** | 1h07m |

Both questions below all four approvals, and the oldest unanswered thing
on the fleet drawn last of the six. Staleness is the thing the operator
should feel, and recency-sorting is precisely what buries it.

## The model

**A signal is derived and never stored.** `Custode.Attention.resolve/2`
computes one `%Custode.Signal{}` per agent from state the fleet already
keeps: the gen_statem status, the durable gate row, the spend ledger, the
cached GitHub overview. There is no table and no migration. Persisting
attention would mean keeping it in sync with the five sources it
summarises, and a stale needs-you badge is worse than none.

**The resolver is pure.** No `Repo`, no registry, no clock it was not
handed. That is what makes the ranking testable against fixtures, and what
lets there be exactly one of it. `Custode.Attention.Fleet` is the impure
half and is deliberately thin: if it grows a decision, the decision is in
the wrong module.

**A signal carries what would clear it.** The `resolving` list means a row
renders its own buttons, so a new kind does not mean a new template branch
on every surface that draws signals. It is the field that earns the struct.

### Kinds, in precedence order

One agent resolves to ONE signal: the first kind whose condition holds.

| # | kind | condition |
| - | ---- | --------- |
| 1 | `:needs_answer` | the agent asked the operator a question |
| 2 | `:approval` | a gate is open only the operator can pass |
| 3 | `:red_check` | failing checks on the agent's own open PRs |
| 4 | `:rail_hit` | the daily rail is reached |
| 5 | `:stalled` | scheduled, running, producing no outcome (NOT BUILT) |
| 6 | `:working` | a turn is executing now |
| 7 | `:paused` | deliberately stopped |
| 8 | `:scheduled` | healthy, next beat known |
| 9 | `:quiet` | healthy, nothing found, nothing queued |

A question outranks an approval because a question is blocked on a human
by definition, whereas a gate is a structured hold the agent chose to
raise and can describe.

### Kinds added since

The table above is the set this record was written against. The code has
since gained seven kinds. `Custode.Attention`'s moduledoc holds the current
precedence; `Custode.Signal` holds the kind type and the group mapping.

| kind | raised by | group |
| ---- | --------- | ----- |
| `:host_down` | the boot doctor failed, so no agent can run; a fact about the host, resolved by `Attention.host/1` with no agent view, and ranked above every per-agent signal (#443) | `:needs_you` |
| `:red_main` | the repository's default branch is failing; first in the per-agent precedence (#310) | `:needs_you` |
| `:turn_failing` | the agent's last turn failed for a reason the next beat cannot fix: one `auth_failed` or `config_error`, or two in a row of any other non-retryable category; second in the per-agent precedence, above a question and a gate (#527) | `:needs_you` |
| `:workflow_launch` | a workflow launch proposal is waiting on the operator's decision; resolved by `Attention.workflows/1`, not per agent (#447) | `:needs_you` |
| `:disowned_check` | a failing check on a PR the agent declared not its work; ranked above `:red_check` (#313) | `:needs_you` |
| `:sensor_failing` | one of the agent's sensors has failed N runs in a row; ranked between `:red_check` and `:rail_hit` (#444) | `:watching` |
| `:workflow_rail` | a workflow run is parked on its budget rail until a human raises it or lets it go; resolved by `Attention.workflows/1` (#447) | `:needs_you` |

### Kind and group are different questions

Precedence decides which kind wins for one agent. The GROUP decides where
it lands on a page, and the two are not the same axis:

```
:needs_answer  :approval  :rail_hit  :stalled  -> :needs_you
:red_check                                     -> :watching
:working                                       -> :working
:scheduled                                     -> :scheduled
:quiet         :paused                         -> :quiet
```

**`:needs_you` means nothing progresses without the operator.
`:watching` means the fleet noticed something and is not blocked on a
human.** That distinction was not in the original design and was forced by
the running fleet within an hour of the page shipping, which is the
argument for shipping the resolver before the screens.

What happened: a pause-all cleared every gate, and the needs-you group was
left holding exactly two things, both red checks, on agents that were
offline, had spent `$0.00`, and read "next beat starts it". Neither had
been given a chance to try. A group that says *2 things need you* when the
honest answer is *the fleet has 2 things to look at tomorrow* is how a
needs-you group stops being believed, and being believed is the only thing
ranking it was for.

Position: **a signal the fleet will act on itself is not attention.** When
a future kind is proposed, this is the test it has to pass.

### Two departures from design/000's table

`:paused` is tested BEFORE `:scheduled`. A paused routine still has a
cron, so the design order reports an agent the operator stopped as healthy
and counting down to a beat it will never run. The precedence claim that
matters is the ordering within the needs-you kinds; the rest states are
mutually exclusive and their order is a correctness question, not a
ranking one.

`:stalled` is defined and NOT implemented. A false stall teaches the
operator to distrust the needs-you group, which costs more than the kind
is worth. It needs a threshold tuned against real sweep history first, and
it stays off until there is one.

### Offline is a rest state, not a fault

Custode routines are cold-started by their own cron (`if_offline: "start"`),
so a healthy scheduled agent reads `:offline` between beats for most of its
life. An offline agent with a cron is `:scheduled`; without one it is
`:quiet`. Neither is a problem, and drawing them as one was a large part of
why the page was hard to scan.

## What the page owes

Every screen is a projection of the resolver and contains no ranking of its
own. The fleet page stacks the groups in order with their counts, collapses
`:quiet` to a line of names, and applies repo grouping (#243) WITHIN a
group rather than across the grid, so a repo's two agents stay adjacent
while they share a group and separate when only one needs a human.

Non-goal: **no surface re-derives attention.** The rail chip was doing
exactly that and now reads the resolver, so the chip and the page header
cannot disagree. `CustodeWeb.Components.needs_attention?/1` survives on its
other job (choosing which feed message a tile shows) and should not grow a
second one.

---

# Part two: the wider design review, dispositioned

The review this doc came from proposed considerably more than attention: a
`mission` / `crew member` vocabulary, a provider seam over multiple agent
CLIs, an operation registry, and alignment with a separate Agent Worker MCP
contract. Recording what custode took and what it did not, so a future
session does not re-litigate it from the source document.

**Taken, and shipped here.** The attention resolver, its ranking, and the
page as a projection of it.

**Taken, not yet built.** The `ask` / `gate` distinction: an approval is a
blocking hold that resumes the same run, whereas a question is a
non-blocking post that leaves the run succeeded and stays open until a
reply closes it. Custode has gates and has no asks. This is the most
valuable small idea in the review and it is what the inbox needs. Also the
inbox itself, the pluggable agent body, and suggestion outcome tracking.

**Deferred on its own merits.** The provider seam and a Codex adapter. Its
payoff is mixed crews and a cheaper model per role, which only pays once
crews exist, and `oban_claude` pins the `claude_wrapper` contract
deliberately, so the sibling adapter is work in another repo.

**Declined for custode.** The Agent Worker MCP contract as a substrate,
the two-implementations plan, and the conformance ladder. That is a
separate specification with its own life; custode's job is to be custode.
The vocabulary is worth borrowing where it is free (run statuses, trigger
kinds, gate-vs-ask), and the surface is not worth reshaping until a second
client exists that needs it. Grants and a clients screen go with it: they
solve a multi-client problem custode does not have, having one operator.

**Undecided, and blocking.** Whether the roster lives in `custode.toml`
(design/003's direction, with `WriteBack` and gated profile mutation
already built) or moves into the database (which `mission` / `crew` and a
`roster.hire` operation assume). These are both coherent and they are not
compatible. Nothing past the agent page should be built until it is
settled.

**A note in favour of missions, from custode's own config.** `redisctl`
and `redisctl-steward` are already two agents on one repository, drawn on
the fleet page as unrelated peers. That is a crew of two in everything but
name. Against it: `reviewer` and `consistency` are fleet-scoped roles with
no repository to belong to, and the review's rule is that a crew member
serves exactly one mission. A partition with an exception is worth knowing
about before any schema is written.

## Next

The rungs, in order, each one useful alone:

1. `ask` versus `gate`, and the inbox as the operator's filtered view.
2. The agent page with a body that swaps on agent kind, and one composer.
3. Suggestion lifecycle and an advisor's track record.
4. The roster-storage decision, then missions and crews if they still earn
   their weight.
