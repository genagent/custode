Custode exposes its agent, repository, notebook, and fleet operations through MCP. This reference describes the public requests and their behavior so a client can use the surface without knowing Custode's implementation language. The generated catalog includes every registered tool, resource, and resource template. Behavior notes describe effects and access checks in addition to the advertised schemas. The companion `mcp-reference.json` contains the machine-readable catalog.

## Endpoints and availability

The default main endpoint is `http://127.0.0.1:6161/mcp`; the memory endpoint is `http://127.0.0.1:6161/mcp/memory`. Both use Streamable HTTP. Port 6161 can be configured, and the listener binds to loopback. Custode does not configure a stdio MCP transport. The generated endpoint inventory records server versions, capabilities, protocol versions, and exact registration counts.

The memory endpoint exposes a restricted selection of tools that also exist at the main endpoint. Configured external servers, such as hexpm or cratesio, are separate connections provided to agents; their interfaces are not re-exported through these endpoints.

The resources describe the work-kernel data model, whose workflow intake is currently frozen. Their read surface remains available. Compatibility Mission records may represent active routines. The `custode://attention` resource includes work-kernel obligations and open legacy asks/gates; it is a different projection from the `list_attention` tool used for current fleet attention.

## Authentication and session setup

Every HTTP request requires `Authorization: Bearer <token>`. The token identifies an operator, routine, or sub-agent. Missing or invalid tokens receive HTTP 401. The main endpoint admits operator and routine identities; the memory endpoint admits only sub-agents. A valid identity at the wrong endpoint receives HTTP 403. Tokens expire across a server restart, and issuing a new token for an identity revokes its previous token. Operator clients can use the local operator token file or the `CUSTODE_OPERATOR_TOKEN` environment override; do not put a real token in shared examples or saved discovery output.

Start with an `initialize` request, inspect the returned protocol version and capabilities, then send `notifications/initialized`. Custode's HTTP surface is stateless and returns no `mcp-session-id`; send the negotiated version in `mcp-protocol-version` on later requests. Clients should accept both `application/json` and `text/event-stream` responses.

Use one of the supported protocol versions in the generated endpoint inventory and verify the server's negotiated version. The example below requests `2025-06-18`. A transport-library upgrade changes this reference only when the deployed contract changes.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "my-custode-client", "version": "1.0"}
  }
}
```

Authenticated operator requests may include `x-custode-origin: cli` for audit attribution. This header does not grant authority and is ignored for that purpose when an agent token is used.

## Discovery and result envelopes

Discover tools with `tools/list`, fixed resources with `resources/list`, and URI templates with `resources/templates/list`. Follow `nextCursor` when discovery responses include it. Tool discovery is filtered by the authenticated identity's endpoint and current routine role. The generated provider allowlist is a compact projection and can omit low-frequency capabilities that the server authorizes, so clients should still discover before calling. Resource discovery returns no resources or templates to routine identities.

Invoke a tool with its public name and JSON arguments:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {"name": "list_routines", "arguments": {}}
}
```

Tool successes generally contain JSON encoded inside a text content block. Parse that text to obtain the operation result. The surface does not currently declare tool output schemas or use MCP task augmentation. An accepted request can schedule work that completes later; the tool's behavior notes identify the return channel and what its immediate success means.

Tool failures generally use `isError: true` and a text explanation. A call that omits a field listed in the tool schema's `required` array also returns `isError: true`, so the model can correct its arguments. Invalid field values, unknown names, and malformed requests can instead return a JSON-RPC `error`; authenticated JSON-RPC errors are carried in an HTTP 200 response. Check both result forms because HTTP success alone does not mean the operation succeeded. After a transport timeout, a write may already have happened. Use an operation's documented idempotency or reconciliation behavior before retrying.

Read resources through `resources/read`:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "resources/read",
  "params": {"uri": "custode://missions"}
}
```

Resource results contain a `contents` entry with the requested `uri`, `mimeType: "application/json"`, and a JSON-encoded `text` body. Resource errors are JSON-RPC errors: resource-not-found (`-32002`) for absent or inaccessible resources, and invalid-params (`-32602`) for invalid cursors. Resource subscriptions are disabled; subscribing or unsubscribing returns method-not-found (`-32601`). Clients must explicitly refresh reads.

## Reading argument and access notes

The schema is the wire-level argument contract. Some arguments marked optional there are still needed to perform the requested operation: the tool deliberately checks them during execution to return a more useful error. Behavior notes also describe defaults, limits, aliases, and conditional requirements that are not fully expressed by the schema.

Several notebook and memory tools accept either `routine_id` or `agent_id`. A nonblank `routine_id` takes precedence, followed by `agent_id`, then the authenticated agent's own ID. An operator must provide a target because the operator has no personal agent records. Notebook/memory writes and journal reads enforce self-scope for agents; the operator can target other identities. Other reads such as `recall`, `todo_list`, and `inbox_list` deliberately allow reading another agent's records.

Each entry distinguishes endpoint and role capability checks from narrower operation checks. The server filters discovery and refuses blind calls outside the caller's capability set. Tool handlers and shared operations separately enforce target ownership, repository policy, approved grants, and human-only decisions; these are documented individually. A descriptive category or client-side allowlist is not a substitute for either server-side layer.

The maintained [authorization matrix](authorization.md) maps identities and
endpoints to intended authority, records current enforcement gaps, and defines
the target server-side boundary.

Resource URI variables are required opaque strings. Percent-encode each path segment and do not infer an ID format or construct cursors. Resource reads do not accept query parameters. List pages contain up to 25 items, a versioned `contract`, pagination metadata, and navigation links. Follow `page.next_uri` until null. Cursors are scoped to their collection; they are continuation handles, not a stable snapshot of changing data.

Routine instructions, prompt files, the `prompt_agent` tool, and an agent's structured permission requests are different mechanisms from MCP prompts. Consult the generated Prompts section for registered MCP prompt templates and their arguments.


## Operator image attachments

An authenticated human client can send one PNG, JPEG, GIF or WebP image with a
message, including an image without text:

1. Call `attachment_upload` with `agent_id`, `media_type` and `data_base64`.
2. Retain the returned `attachment_id`.
3. Call `prompt_agent` with the same `agent_id`, that `attachment_id`, a stable
   `idempotency_key`, and `prompt` (use an empty string for image-only messages).
4. Follow the returned `message_id` with `await_agent`. The receipt includes its
   `attachment_id`; acceptance does not mean the provider has read the image.

Uploads and reads are human-only. A reference belongs to the verified operator
identity and the target routine, regardless of client or transport. Knowing a
reference does not let a different operator read or submit it, and routine and
helper identities cannot use attachments. No upload or retrieval argument names
a server filesystem path. `attachment_read` returns metadata and base64 bytes to
the owning operator. The dashboard's existing authenticated image routes remain
available to the local operator.

The shared UI/MCP limit is 10,000,000 decoded bytes per image. The main MCP HTTP
endpoint accepts at most 14,000,000 body bytes to accommodate base64 and JSON;
the memory endpoint remains limited to 2,000,000 bytes. Upload validation checks
size and recognized image headers against the declared type. It does not decode
or sanitize the complete image, or establish that a downstream decoder will
accept it. JPEG uploads use the canonical `image/jpeg` type.

Identical live uploads by the same operator to the same routine/workspace return
the same reference. Uploading alone does not start an agent. Prompt submission
uses the existing start/resume/queue operation, atomically retaining the image
reference with the message before provider admission. Its idempotency fingerprint
uses the submitted text and reference, not a workspace path. Retrying an accepted
message with the same key and input returns its retained receipt even after bytes
expire or the routine moves; it does not start another turn. A changed text or
reference under that key conflicts. New submissions require available bytes in
the current routine workspace.

Cleanup follows the configured upload retention (30 days by default). Abandoned
uploads age from upload time. Queued, executing, waiting-for-input and
waiting-for-approval messages protect their image regardless of age. After the
last referencing message settles, retention runs from its last update. Cleanup
keeps reference metadata and message receipts after removing bytes, so old
receipts remain meaningful but retrieving an expired image fails. Disabling
upload retention disables this cleanup. This is an age policy, not a storage
quota or a promise that bytes survive manual filesystem changes.
