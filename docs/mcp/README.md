# Maintaining the MCP client reference

Readers start at [the reference](../mcp-reference.md). The companion
[JSON catalog](../mcp-reference.json) carries the same semantic notes plus the
complete advertised definitions. Neither output requires knowledge of Elixir.

Regenerate from the repository root:

```sh
mix custode.mcp.docs
mix custode.mcp.docs --check
```

The command compiles definitions without starting Custode. It never executes a
tool, reads a resource payload, opens a database or listener, looks up credentials,
or contacts a deployed fleet. The committed output describes this source revision;
a running server can lag it until updated. Schema required-field lists are sorted as unordered sets; other array order is
preserved. No timestamps, local paths, fleet data
or tokens are collected.

## Sources and review

- `overview.md`: language-neutral connection, identity, discovery and result guide.
- `authorization.md`: identity and endpoint capability matrix, actual enforcement,
  known gaps, and the planned server-side boundary.
- `behavior.json`: reviewed summaries, results, side effects, access checks and
  behavioral notes keyed by public name. Tools also require a short `summary`.
- Server registrations: exact tool schemas, public discovery metadata, endpoint
  membership, supported protocols and capabilities.
- Resource registration: the same pure operator registration used by the server,
  including URI templates. Reads are never invoked.
- Tool policy: descriptive category only; access notes must describe actual guards.

When changing an MCP capability, update its behavior notes and regenerate both
outputs in the same PR. Review defaults, semantic requirements, output shape,
errors, asynchronous completion, identity scope, retries and effects on files,
the database, running agents and external services. JSON Schema alone cannot
infer those semantics. A changed implementation without a schema change still
needs a behavior review; the generator cannot prove prose is correct.

Coverage validation refuses missing or stale entries and empty descriptions.
The test suite compares generated output byte for byte with the committed files.
CI also runs `--check` before booting the test application. Adding a prompt or a
new resource requires notes just like adding a tool. The exporter rejects a
shared name with conflicting endpoint definitions instead of silently choosing
one. New endpoints or new runtime registration paths require updating the small
extraction adapter in `Custode.MCP.Reference`.

Keep runtime-library details inside the Snodo adapter. The
public reference, JSON catalog and semantic metadata remain client-facing.
