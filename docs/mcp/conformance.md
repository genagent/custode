# Independent MCP conformance proof

This bounded proof references #848; it does not close it. The consumer is
`scripts/mcp_conformance.py`, a Python 3 standard-library HTTP JSON-RPC client.
It imports no Custode or Elixir code, reads no database or local contracts,
and makes assertions only from public HTTP responses. It uses advertised
input schemas and the current v1 result contracts documented in
`docs/mcp-reference.json` and `docs/mcp/behavior.json`.

Run the ExUnit wrapper against an isolated disposable test database and a
test listener from a sibling worktree. Follow the repository validation gates
and app-boot cooldown. For example, with the worktree's isolated database
configuration already in place:

```sh
CUSTODE_TEST_MCP_PORT=6185 mix test test/custode/mcp_client_conformance_test.exs --seed 1
```

Repeat with seeds 12345 and 777. Never point this proof at a running fleet,
its main checkout, or its fixed port. Do not start a development server for
this test. The wrapper derives its port from the verified test application
configuration and passes `Custode.MCP.url()` explicitly to the client. The
optional `CUSTODE_TEST_MCP_PORT` override selects a worktree-specific port;
ordinary test/CI runs can use the test configuration's default 6171. Test
mode, disabled queues/scheduling and the test MCP config directory remain
required. There is one ExUnit test per protocol, each with its own unique
synthetic configured owner. Each restores the application environment and
cleans up its agreement rows afterwards. Queues and scheduling must be
disabled. Credentials are minted by the fixture and passed through the child
environment without changing the parent's environment. Python 3 is required.

For an independently prepared disposable fixture with exactly one configured
synthetic owner and no agreements, the equivalent consumer invocation is:

```sh
python3 scripts/mcp_conformance.py --url http://127.0.0.1:6185/mcp --owner SYNTHETIC_OWNER --protocol 2026-07-28
```

Supply `CUSTODE_CONFORMANCE_OPERATOR_TOKEN` and
`CUSTODE_CONFORMANCE_ROUTINE_TOKEN` through the child environment using the
fixture's credential provisioning. Do not pass credentials as CLI arguments
or print them. The routine token must belong to that synthetic owner. The
client creates two agreements, so use a fresh fixture for each full run.
Choose `--protocol 2025-11-25` or `--protocol 2026-07-28` explicitly.
There is no default URL, owner or protocol. References in submissions are synthetic
opaque links and are never opened.

The proof covers:

- Initialize and initialized for 2025-11-25; direct stateless calls without
  initialize for 2026-07-28. Modern requests send `Mcp-Method`, tool calls
  send `Mcp-Name`, and `params._meta` contains the namespaced protocolVersion
  and clientCapabilities fields; legacy requests keep initialize-era framing.
  Every invocation checks discovery of eight required tools and input-schema
  parity across both versions, then runs the entire lifecycle, error and
  recovery journey under the selected protocol. The two ExUnit tests run the
  full journey once for each version.
- Configured-owner project progress and the bounded project report digest.
- Create followed by an exact request-id retry, simulating a discarded reply.
  The original receipt is retained only for comparison. The retry returns the
  same receipt with `duplicate=true`; recovery proves no extra history row
  or agreement was created.
- Owner checkpoint and submission with criterion evidence and explicit
  verification limits, exact synthetic human acceptance, then revised intent.
  A new stale resolution request is refused. Prior acceptance stays bound
  to the original revision and submission and does not accept current intent.
- A fresh Python interpreter receives the URL, owner, selected protocol and credential.
  It rediscovers tools, traverses two agreement pages and five history pages,
  and reconstructs the retained record and outcome without mutation receipts
  or transcript state. Unique IDs and exact sequences prove no duplicate or
  omitted rows in this disposable fixture.
- Missing and invalid authorization as HTTP 401, unknown method as a JSON-RPC
  error (HTTP 404 under 2026-07-28, HTTP 200 under 2025-11-25),
  HTTP 200 `isError` tool refusal, and a routine token's human-only
  resolution refusal as capability error -32003. Unsupported is never
  counted as delivered.

Success prints one concise JSON object with the selected journey's
`protocol_versions`, both `discovery_protocol_versions`, the selected
`protocol_setup`, schema versions, proof markers and recovery counts, without
tokens, identity IDs or account data. Discovery coverage is distinct from
full journey coverage.
Each request has a five-second timeout; each client has a 45-second/80-request
budget, discovery and cursor loops have bounded pages, responses have a size
limit, and the reconnect subprocess has a 50-second timeout. Network and
contract failures exit nonzero with sanitized diagnostics. JSON error bodies
are decoded within the response size limit even on non-200 statuses;
plain-text authorization refusals remain HTTP errors. RPC failure diagnostics
include only fixed check names, protocol version, method, HTTP status and
numeric error code, never response bodies, tokens or identities. No proxy is
used. Redirects are refused.
Before surfacing child output, the wrapper checks for private fixture data
with a boolean assertion and fixed sanitized message. It checks proof markers and counts as well as exit status, then
checks that jobs, durable messages and owner inbox wakes did not increase.
It performs no model or provider calls.

Remaining #848 journeys include durable prompt/status/outcome journeys using
deterministic provider fixtures, server restart recovery, attachments,
remaining #846 operator verbs, stopping and delegation. This proof reconnects a client; it does not restart the server.
Synthetic evidence and a fixture-issued human judgment prove attributed
agreement bookkeeping, not real work delivery or independent verification.
No API, schema, transport or authorization rules change in this slice.
