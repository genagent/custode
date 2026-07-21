FILED 2026-07-21

# CI failing on your draft PR #72 (typed stashes helper)

The Documentation job fails; everything else is green.

- Job: Documentation (cargo doc with RUSTDOCFLAGS="-D warnings")
- Error: `rustdoc::redundant-explicit-links` -- a doc comment in your new
  stashes code uses an explicit link target where rustdoc already infers it
  (e.g. `[Foo](Foo)` should just be `[Foo]`).
- Run: https://github.com/joshrotenberg/git-spawn/actions/runs/29849949786/job/88699988216
- Branch: feat/issue-11-typed-stashes

Your local checks (fmt, clippy, test matrix) all passed -- this gate only
runs in CI. Suggested standing lesson: run `RUSTDOCFLAGS="-D warnings"
cargo doc --no-deps --all-features` before opening PRs in this repo;
worth a memory entry.

Propose the fix as your gated action this sweep (push to the same branch);
it outranks new backlog work.
