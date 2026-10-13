# Local fixture qualification

Observed on 2026-10-13 in the isolated `test/880-gen-agent-adapter-proof` worktree.

| Check | Result |
| --- | --- |
| Deterministic matrix, seed 1 | 15 passed |
| Deterministic matrix, seed 12345 | 15 passed |
| Deterministic matrix, seed 777 | 15 passed |
| Standalone format, compile with warnings as errors, Credo, Dialyzer | Passed |
| Custode test suite | 2,710 passed, 3 excluded |
| Custode format, compile with warnings as errors, Credo, Dialyzer | Passed |
| Synthetic native processes after the matrix | None remained |

Host: `aarch64-apple-darwin27.0.0`, Elixir 1.20.4, OTP 29, Python 3.13.0.
Resolved runtime: GenAgent 0.7.0, GenAgent Claude 0.2.7, ClaudeWrapper 0.15.3,
Forcola 0.6.0, Oban 2.24.1, Ecto SQLite3 0.25.0. The Forcola shim SHA-256 was
`C93B1FAA5BD29B9FEB8C4FF203747AE6BE115556C75114E7981ACF31F9159504`.

The native witness captured the effective CLI arguments, including model
`fixture`, `--permission-mode dontAsk`, `--max-turns 1`, an empty tools list,
and the disposable working directory. It also recorded the actual CLI/tool
process IDs and groups independently of the normalized GenAgent response.

The decisive positive result is B1-B3: killing the actual Oban executor at
three different barriers preserves one independent receipt/report and does
not produce another invocation on redelivery. The decisive negative result
is C4: after abrupt lead death and confirmed parent exit, the escaped tool
still writes. The journal retains uncertainty and the active slot rather
than claiming the provider stopped. C3 and C4b observe the closed group's
exit but retain the unknown outcome; native exit does not invent a report.

These results qualify the fixture host protocol, not production process
containment, automatic orphan rescue, full host recovery, or a real provider.
See the README for the matrix and the runner settlement gap. Dedicated Linux
CI wiring was prepared but could not be published because the current GitHub
credential lacks workflow scope. No Linux qualification is claimed. Existing
repository CI does not run this standalone proof.

No live Claude/Codex request or delegated model review was run. The running
fleet was not changed, migrated or restarted. The broader #777 remains open.
