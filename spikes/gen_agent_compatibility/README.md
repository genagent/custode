# Released GenAgent compatibility proof

This separate Mix project pins core 0.6.2, ensemble 0.6.1, Claude adapter 0.2.6
and Codex adapter 0.5.0 alongside Custode's current ObanClaude 0.10.1,
ObanCodex 0.7.0, ClaudeWrapper 0.15.3, CodexWrapper 0.6.0 and Forcola 0.6.0.
Its lockfile
records a resolved, compiled released dependency set. It does not add runtime
dependencies to Custode.

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

Six additional tests exercise the default released provider backends through
actual wrapper argument builders and parsers, with an in-memory runner that
cannot start a subprocess. They cover fresh/resumed model, effort, schema and
permission arguments, early identities before failure, final Codex response
text, unknown usage on external restore, later known deltas and unsupported
continuation/cap options. The optional Forcola runner modules also compile
with Custode's pinned cleanup dependency; no process settlement is tested.
These tests call backend callbacks directly; the core/coordinator tests above
use a separate fixture backend.

The fresh and resumed provider fixtures require the explicit `timeout: 500`
to reach both Claude and Codex runners. ClaudeWrapper 0.15.3 fixes the dropped
streaming deadline in 0.15.2. This standalone runner cannot prove elapsed-time
enforcement or cleanup. The root `Custode.SubprocessCleanupTest` additionally
checks a continuously emitting no-model CLI through the configured Forcola
runner, including terminal truncation and fixture parent/child cleanup. The
default Port runner still cannot guarantee subprocess-tree cleanup.
`tools: [""]` supplies the empty CLI tool argument; `tools: []` merely omits
that flag.

In this standalone project, no provider CLI, paid request, live fleet, network
MCP endpoint, approval gate or external subprocess is exercised. Killing the fixture task does not prove that
Claude/Codex subprocesses have stopped. Source inspection of released provider
adapters is recorded in design/016 and design/017. The core's optional restore
callback is not automatically called; a host must persist and supply the id.
This proof supports design decisions, not a live migration claim.
