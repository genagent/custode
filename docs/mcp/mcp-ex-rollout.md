# mcp_ex transport rollout

Custode pins the private `mcp_ex_plug` package at commit
`6e357655210f7f146c967f702e46be7f724866d5`. The migration replaces the two
Anubis HTTP server processes and their session transport. Existing Anubis tool
components, Peri validation, Frames, Responses, and work-resource reads remain
the callback layer for this slice.

The HTTP service is stateless. Initialize-era clients negotiate either
`2025-11-25` or `2025-06-18`, receive no `mcp-session-id`, and send the negotiated
version in `mcp-protocol-version` on later requests. `2026-07-28` remains the
first protocol in discovery. Cross-request cancellation is disabled because
Custode does not yet issue a signed client-instance identity separate from its
bearer identity. Request execution is bounded at 16 concurrent requests, 64
queued requests, and 16 minutes per admitted request.

`Custode.MCP.Capabilities` is installed as the mcp_ex runtime authorization
policy. It filters discovery and refuses a blind call before argument
validation or a tool/resource callback. The same module continues to project
provider allowlists and to enforce the legacy callback path while that adapter
remains. Endpoint admission is checked before MCP dispatch, so a valid identity
on the wrong endpoint receives HTTP 403; component refusals inside an admitted
endpoint are JSON-RPC errors with HTTP 200.

## CI dependency access

The mcp_ex repository has one read-only deploy key titled
`Custode Actions mcp_ex read-only`. Custode Actions expects its private half in
the `MCP_EX_DEPLOY_KEY` repository secret. Both CI jobs use that key only in an
`actions/checkout` step pinned to the commit above, then set `MCP_EX_PATH` to
the checkout. Local development may set the same variable to an mcp_ex source
checkout; otherwise Mix fetches the pinned Git dependency through SSH.

## Rollout

1. Pull the Custode revision and run `mix deps.get` while the private dependency
   credential is available.
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

The development acceptance run exercised the real server with native Claude
Code and Codex clients. Each client used a scoped sub-agent bearer identity,
called `remember`, called `recall`, and returned the value stored in isolated
test state.

## Failure checks

- A request without a bearer token returns HTTP 401 on both endpoints.
- An operator on `/mcp` lists the full tool catalog; routine discovery is
  filtered by its role. A sub-agent on `/mcp/memory` lists only `journal_read`,
  `remember`, `recall`, and `forget`.
- Work resources are listed for the operator catalog and remain absent from a
  routine catalog.
- Initialize responses contain the negotiated protocol version and no session
  header. Later initialize-era requests without `mcp-protocol-version` fail.
- The boot probe stays fail-open after its existing 60 second window, with a
  loud warning, so a transport failure does not permanently silence the fleet.
- Missing private dependency credentials fail during checkout or `mix deps.get`
  before compilation. Rotate the deploy key rather than broadening its access.

## Rollback

Revert the Custode migration commit, run `mix deps.get`, and restart Custode.
That restores the Anubis server children and session-aware Streamable HTTP plug.
The mcp_ex deploy key may remain read-only for investigation or be removed from
both repositories after the rollback. No data rollback is required.
