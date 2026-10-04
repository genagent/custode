# Snodo transport rollout

Custode consumes `snodo_plug ~> 0.4.1` from Hex. Snodo supplies the stateless
HTTP MCP transport while the existing Anubis tool components, Peri validation,
Frames, Responses and work-resource reads remain the callback layer.

The HTTP service is stateless. Initialize-era clients negotiate either
`2025-11-25` or `2025-06-18`, receive no `mcp-session-id`, and send the negotiated
version in `mcp-protocol-version` on later requests. `2026-07-28` remains the
first protocol in discovery. Cross-request cancellation is disabled because
Custode does not yet issue a signed client-instance identity separate from its
bearer identity. Request execution is bounded at 16 concurrent requests, 64
queued requests and 16 minutes per admitted request.

`Custode.MCP.Capabilities` is installed as the Snodo runtime authorization
policy. It filters discovery and refuses a blind call before argument
validation or a tool/resource callback. The same module continues to project
provider allowlists and enforce the legacy callback path while that adapter
remains. Endpoint admission is checked before MCP dispatch, so a valid identity
on the wrong endpoint receives HTTP 403. Component refusals inside an admitted
endpoint are JSON-RPC errors with HTTP 200.

## Dependency and transport behavior

Both `snodo` and `snodo_plug` are public Hex packages. A fresh checkout uses
ordinary `mix deps.get`; CI needs no source checkout, SSH credential or deploy
key for them.

Snodo 0.4 bounds request bodies at 2 MB and requires `Content-Length`; a request
that declares `Transfer-Encoding` receives HTTP 411. Custode's JSON clients send
a fixed body with a content length. When a handler is still silent after five
seconds, the Plug changes the response to SSE and writes keepalives so a client
disconnect can cancel abandoned work. The Custode CLI accepts both JSON and SSE
terminal responses.

Snodo 0.4 compiles resource templates against its supported RFC 6570 shapes and
refuses unsupported forms, templates longer than 1,024 bytes and templates with
more than 32 variables. Custode's 13 templates use literal path segments and
single-segment variables; the transport contract test compiles every advertised
template. The 0.4 line also rejects duplicate JSON object keys, closes Plug
streams when their request executor exits and releases request-only data from
long-lived subscription streams. Custode does not enable the new proxy, client
cache, OAuth listener, per-component middleware or Tasks facilities.

## Rollout

1. Pull the Custode revision and run `mix deps.get`.
2. Run the five repository gates and `mix custode.mcp.docs --check`.
3. Stop the running Custode instance cleanly and restart it from the updated
   checkout. No database migration is part of this change.
4. Confirm the boot log reports `MCP surface answered; starting the ticks queue`.
5. Run one CLI read and one isolated CLI write. Confirm the resulting operation
   audit records `transport: "cli"`.
6. Connect Claude and Codex through their ordinary MCP configurations. On each
   client, list tools on `/mcp`, list the four memory tools on `/mcp/memory`,
   and perform one isolated remember/recall pair. Codex configurations used for
   autonomous runs set `default_tools_approval_mode = "approve"` for the
   authenticated Custode server; otherwise a non-interactive `never` approval
   policy rejects the write before it reaches Custode.
7. Exercise one request that runs longer than five seconds and confirm the
   client accepts Snodo's SSE keepalive response before the terminal result.

## Failure checks

- A request without a bearer token returns HTTP 401 on both endpoints.
- An operator on `/mcp` lists the full tool catalog; routine discovery is
  filtered by its role. A sub-agent on `/mcp/memory` lists only `journal_read`,
  `remember`, `recall` and `forget`.
- Work resources are listed for the operator catalog and remain absent from a
  routine catalog.
- Initialize responses contain the negotiated protocol version and no session
  header. Later initialize-era requests without `mcp-protocol-version` fail.
- Missing schema-required tool arguments return an HTTP 200 tool result with
  `isError: true`; other authenticated JSON-RPC errors are also carried over
  HTTP 200. Endpoint admission failures retain their transport-level 4xx status.
- A transfer-encoded request receives HTTP 411 without reaching a callback.
- The boot probe stays fail-open after its existing 60 second window, with a
  loud warning, so a transport failure does not permanently silence the fleet.

## External cleanup

After the released package has passed the rollout, the obsolete read-only
GitHub deploy key and repository secret can be removed. Custode no longer reads
either one.

## Rollback

Revert the Snodo migration commit, run `mix deps.get`, and restart Custode. No
data rollback is required.
