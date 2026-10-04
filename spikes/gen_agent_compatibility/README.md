# Released GenAgent compatibility proof

This separate Mix project pins core 0.6.2 and ensemble 0.6.1. Its lockfile is
part of the proof. It does not add runtime dependencies to Custode.

From this directory:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --seed 1
mix test --seed 12345
mix test --seed 777
```

The six tests use the real released core/coordinator with a fixture backend:

- Checkpoint before terminal failure, continued use, and loss on core restart.
- Host checkpoint persistence before completion and explicit restore at a fresh
  runtime boundary. File persistence is a fixture seam, not Custode's database.
- Per-turn call options do not override the captured backend model/tool options.
- A cancelled turn's checkpoint closure cannot change its successor.
- Two concurrent reviews, success and partial failure, and repeated actual child
  completion envelopes cannot replace their results or notify twice.
- Cancellation closes the token; actual late child envelopes remain fenced.

No provider CLI, paid request, live fleet, network MCP endpoint, approval gate or
external subprocess is exercised. Killing the fixture task does not prove that
Claude/Codex subprocesses have stopped. Source inspection of released provider
adapters is recorded in design/016 and design/017. The core's optional restore
callback is not automatically called; a host must persist and supply the id.
This proof supports design decisions, not a live migration claim.
