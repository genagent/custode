# UI design session, 2026-07-25

Output of the Claude design sessions that reviewed the dashboard as it stood
on 2026-07-25. design/007 part two dispositions the review's wider proposals.
design/010 says which of these screens the project builds from.

Until 2026-09-19 these files existed only in the operator's `~/Downloads`.
Nothing in `lib/custode_web` was built from them.

## Contents

| File | What it is |
|---|---|
| `Custode System Spec.dc.html` | The spec: vocabulary, the attention resolver, providers, the operation registry, screens, migration, open questions. Open in a browser; it loads `doc-page.js` and `support.js` from this directory and fonts from Google. |
| `Custode Fleet Directions.dc.html` | Second document: fleet page directions, the suggestion lifecycle screens, and a REPL concept. |
| `github.md` | The session's own note on what it read from `oban_claude` to ground the providers section. |
| `figures/` | 13 mockups, indexed below. |

Not imported: `uploads/` (52 MB of screenshots of the 2026-07-25 dashboard)
and `repol-brief.md` (a separate project).

The spec describes its screens as directional: layouts settled enough to
build against, copy and spacing not. Every screen is a projection of the
resolver and contains no ranking of its own.

## Figures

Status is as of design/010.

| Figure | Shows | Status |
|---|---|---|
| `console.png` | Spec FIG 11. Rail of subjects grouped needs-you / working / scheduled / quiet; subject pane with tabs and a message button; item pane with evidence and "what custode can do". | **Build from this.** Rung 2, #450. |
| `attention-stream.png` | Spec FIG 10, "the conservative path". The fleet as rows ranked by the resolver, a needs-you banner, quiet agents collapsed to one line. | Reference for the console's rail and row copy. Most of it shipped in #296 and #298. |
| `custode-root.png` | custode as root: a sentence box, a previewed plan with `do it` and `show me the config diff`, suggested sentences, and "what custode did while you were away". | **Build from this.** Rung 3, #451. Ignore the crew vocabulary. |
| `question-inline.png` | A question answered in place: the agent's evidence on the left, the decision it is really asking for, a reply box and canned replies on the right. | Reference for the console's item pane. |
| `inbox.png` | The inbox: needs-you rows with their own buttons, then suggestions, then "That's everything." | Shipped in #301 and #308. The `raised`, `digests` and `archived` tabs were not built. |
| `watch-agent-page.png` | The agent page for a watch-type agent with no repository. | Shipped as the pluggable agent body, #333. |
| `ops-catalog.png` | The operations catalog grouped by domain with risk badges. | #423, unscheduled while the kernel is frozen. |
| `ops-form-detail.png` | One operation's argument form generated from its schema, with dry run. | #423. |
| `provenance-log.png` | The operation log, one row per call, with a copyable invocation. | #424, unscheduled while the kernel is frozen. |
| `fleet-missions.png` | The fleet grouped by mission. | Depends on missions and crews. #421 closed as not planned. |
| `mission-page.png` | One mission's page. | Same. |
| `mission-crew-detail.png` | One crew member inside a mission. | Same. |
| `clients-grants.png` | Connected clients and their grants. | Declined in design/007: custode has one operator. |
