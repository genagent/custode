# The visibility hierarchy

The written outcome of the #31 audit: what deserves visual weight, in
what order, on every dashboard surface. New UI goes through this list
before it picks a component or a color.

## The ranking

Rank by **what the operator does next**:

1. **Blocked on a human.** Open gates, unanswered questions, pauses
   (budget or manual), failing checks on an agent's own PR. Nothing else
   on the page matters more than these; they get red/yellow, top-of-sort,
   and the attention chip.
2. **In motion.** Running turns, in-flight approved work. Visible and
   calm -- the operator chose this; it needs monitoring, not action.
3. **Results awaiting review.** Fresh draft PRs, new journal entries,
   finished one-shot reports. Discoverable in one click, never shouting.
4. **Ambient state.** Idle, offline, cron cadence, spend-within-rails,
   tags. Muted text, not badges; the absence of alarm IS the signal.

The corollary that catches most regressions: **a surface may only shout
at rank 1.** If something grey feels like it needs a badge, it is either
actually rank 1 (promote it) or it does not need the badge.

## The palette

One meaning per color family, enforced by `status_class/1` and
`feed_badge/1` in `CustodeWeb.Components`:

| Color | Meaning | Statuses / events |
|---|---|---|
| red (`error`) | blocked on you | paused (any reason), turn_failed |
| yellow (`warning`) | wants you | needs approval, needs answer, stale gates |
| blue (`info`) | working | running |
| grey (muted text) | ambient | idle, offline, ended, cron, tags |

Purple/accent and green are decorative only (suggestion badges, success
chips); they never carry attention semantics.

## Standing rules

- **Statuses have one vocabulary**: `status_label/1` + `status_badge/1`
  are the only way a status renders (fleet tile, agent header, feed,
  chip). Never inline a status string.
- **Failures say what happens next.** Every failure surface carries the
  recovery path ("re-gated, approve to continue" / "will retry next
  beat"), via `feed_text/1`'s failure hints.
- **Pauses say why.** A budget pause reads "paused -- daily rail", not a
  bare "paused" (`paused_reason/2`).
- **Numbers**: dollars through `usd/1` (two decimals), tokens through
  `tok/1`. No raw floats.
- **Times are relative** (`ago/1`) with the absolute on hover/title.
- **Agent prose is markdown** (`markdown/1`); machine detail (inspect
  dumps, raw payloads) lives behind a disclosure, never open by default.
- **Questions are content, not alarm.** The ask panel presents the
  question at reading weight in a quiet container; only the badge and
  chip carry the "wants you" color.
