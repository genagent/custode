repo: genagent/oban_claude
branch: main

Read for reference only — no files copied into this project. Used to ground the
provider/turn section of `Custode System Spec.dc.html` in the libraries custode
already builds on (`oban_claude`, and `claude_wrapper` beneath it).

## Last sync

date: 2026-07-25T18:12:31Z

### Updated in this project

- Section 4 of the spec renamed "Providers — and what already exists", with a table mapping `oban_claude` primitives to what custode adds on top.
- Attention resolver: noted that `needs_answer` / `approval` map to existing `ObanClaude.Agent.Instance` directives (`ask_user` → `:waiting_for_user`, `request_permission` → `:awaiting_permission`) rather than being new machinery.
- Recorded that spend must sum telemetry `:stop` **and** `:exception` (a budget rail-stop still spent money), and that `args` / `pinned_args` precedence is the implementation of the mission-rules panel in FIG 2.
- Noted Codex needs a sibling adapter rather than changes to `oban_claude`, which pins the `claude_wrapper` contract deliberately.

## Screen map

| Artifact | Built from |
| --- | --- |
| `Custode System Spec.dc.html` § 3 Attention resolver | `README.md` (agent layer: directives, states) |
| `Custode System Spec.dc.html` § 4 Providers | `README.md`, `mix.exs` (deps, version pins, telemetry, args/pinned_args, worktrees, propose/dispose) |
| `Custode System Spec.dc.html` § 5 Operation registry | `README.md` ("what it does NOT do" — lifecycle vs operations boundary) |
| `Custode Fleet Directions.dc.html` | User-supplied screenshots only; no repo content |
