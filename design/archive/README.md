# Archived design docs

These docs did their job. A design doc is **pre-implementation thinking**:
once it has been exploded into issues and every derived issue is shipped, it
has served its purpose and moves here -- out of the active `design/` set, but
kept for the reasoning and history.

Active `design/` holds the docs still driving work, plus two that never
retire: `000-the-operated-fleet.md` (the canonical model) and
`002-storage-doctrine.md` (a standing doctrine).

## Retired

| Doc | What it drove | Landed as |
|-----|---------------|-----------|
| `001-auto-setup.md` | routines.toml loader + write-back + the add/edit roster tools + the new-agent form + `--home` rooting | #41, #75, #174, and the dashboard form |
| `003-binary-layout.md` | CUSTODE_HOME/XDG directory rooting, the structured `custode.toml` sections, prompt assets under `priv/` with config-dir overrides, and the declarative definition loader | #267 (as #294), #268, #269 and #270 (both as #416) |
| `004-telemetry-and-advisors.md` | `Custode.Digest`, config-driven advisors, the judgment grade + `Advisors.Retro`, the presence-return digest, the telemetry-coverage audit | #259, #260, #261, #262, #263 |
| `005-workflows.md` | `Custode.Workflow` + runner + node-results table, the launch gate and run budget rail, the launch button, the backlog-dryness suggestion path, and the deep-report catalog entry | #271, #272, #273, #274, #275 |
| `006-repo-stewardship.md` | the batch filing gate, deterministic verification commands and their evidence, repository health projected from that evidence, and control WorkItems raised from systemic drift | #241, #244, #245, #246 |

To retire another: confirm every issue derived from the doc is closed (and it
is not `000`/`002`), then `git mv design/00N-*.md design/archive/` and add a
row here. Prose citations in code comments are left alone -- `design/004` is
still named in several moduledocs, and this table is how a reader finds it.

One caveat the shipped-issues test does not cover. `008-work-first-kernel.md`
GOVERNS rather than plans: it states where it supersedes earlier records, so
retiring it would leave those supersessions unrecorded and make design/000
read as current on points it no longer governs. Its issues shipping is
therefore not sufficient grounds to archive it; that is a doctrine call, the
same way `000` and `002` are.
