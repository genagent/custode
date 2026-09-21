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
| red (`error`) | blocked on you | paused (any reason), turn_failed, the `:turn_failing` signal (#527) |
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

## The themes

Two daisyUI 5 themes, defined once in `CustodeWeb.Layouts.theme_css/1` from
the 2026-07-25 design session: `paper` (the light mockups) and `ink` (the dark
`custode-root.png`). The page follows the OS preference; the header's `theme`
button overrides it and is remembered in `localStorage` under `custode-theme`.

They are tokens and nothing else. A page styles itself with the semantic
classes and wears either theme with no change:

| Token | paper | ink | Means |
|---|---|---|---|
| `base-200` | `#fbf9f4` | `#161511` | the ground |
| `base-100` | `#ffffff` | `#201f1b` | a card |
| `base-300` | `#e9e4d8` | `#34322b` | a hairline |
| `primary` | `#4f46e5` | `#e8c55a` | the one thing to press |
| `neutral` | `#1c1a17` | `#ece8dc` | the secondary button |
| `warning` | `#b8860b` | `#e8c55a` | wants you |
| `error` | `#dc2626` | `#f87171` | blocked on you |
| `info` | `#0f766e` | `#5eead4` | working |
| `success` | `#15803d` | `#6ee7a0` | done, green |

Names, ids and metadata are set in the mono face (`font-mono`, JetBrains Mono);
prose is the sans (Fira Sans). Cards are drawn with a hairline, not a shadow.
Never hardcode a colour in a page: a hex value is a page that only works in
one theme.
