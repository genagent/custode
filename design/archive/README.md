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
| `004-telemetry-and-advisors.md` | `Custode.Digest`, config-driven advisors, the judgment grade + `Advisors.Retro`, the presence-return digest, the telemetry-coverage audit | #259, #260, #261, #262, #263 |

To retire another: confirm every issue derived from the doc is closed (and it
is not `000`/`002`), then `git mv design/00N-*.md design/archive/` and add a
row here.
