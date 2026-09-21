Custode exposes its agent, repository, notebook, and fleet operations through MCP. This reference describes the public requests and their behavior so a client can use the surface without knowing Custode's implementation language. The generated catalog includes every registered tool, resource, and resource template. Behavior notes describe effects and access checks in addition to the advertised schemas. The companion `mcp-reference.json` contains the machine-readable catalog.

## Endpoints and availability

The default main endpoint is `http://127.0.0.1:6161/mcp`; the memory endpoint is `http://127.0.0.1:6161/mcp/memory`. Both use Streamable HTTP. Port 6161 can be configured, and the listener binds to loopback. Custode does not configure a stdio MCP transport. The generated endpoint inventory records server versions, capabilities, protocol versions, and exact registration counts.

The memory endpoint exposes a restricted selection of tools that also exist at the main endpoint. Configured external servers, such as hexpm or cratesio, are separate connections provided to agents; their interfaces are not re-exported through these endpoints.

The resources describe the work-kernel data model, whose workflow intake is currently frozen. Their read surface remains available. Compatibility Mission records may represent active routines. The `custode://attention` resource includes work-kernel obligations and open legacy asks/gates; it is a different projection from the `list_attention` tool used for current fleet attention.

## Authentication and session setup

Every HTTP request requires `Authorization: Bearer <token>`. The token identifies an operator, routine, or sub-agent. Missing or invalid tokens receive HTTP 401. Tokens expire across a server restart, and issuing a new token for an identity revokes its previous token. Operator clients can use the local operator token file or the `CUSTODE_OPERATOR_TOKEN` environment override; do not put a real token in shared examples or saved discovery output.

Start with an `initialize` request, inspect the returned protocol version and capabilities, then send `notifications/initialized`. Retain the returned `mcp-session-id` header for subsequent requests. Clients should accept both `application/json` and `text/event-stream` responses.

Use one of the supported protocol versions in the generated endpoint inventory and verify the server's negotiated version. The example below requests `2025-06-18`. A future transport-library migration does not change this reference until the deployed contract changes.

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

Discover tools with `tools/list`, fixed resources with `resources/list`, and URI templates with `resources/templates/list`. Follow `nextCursor` when discovery responses include it. Resource discovery returns no resources or templates to routine and sub-agent identities. Main-endpoint tool discovery is not filtered by an agent's configured client allowlist, so discovery alone does not establish permission to execute a tool.

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

Tool failures generally use `isError: true` and a text explanation. Invalid arguments or unknown names can instead return a JSON-RPC `error`. Check both forms; HTTP success alone does not mean the operation succeeded. After a transport timeout, a write may already have happened. Use an operation's documented idempotency or reconciliation behavior before retrying.

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

Each entry distinguishes intended usage from implemented access checks. A tool's category, presence in discovery, or absence from a client-side allowlist is not a substitute for a server-side authorization check. Some tools enforce operator identity, caretaker role, target ownership, repository policy, or approved action grants; these are documented individually. Do not assume one blanket access rule covers all write tools.

Resource URI variables are required opaque strings. Percent-encode each path segment and do not infer an ID format or construct cursors. Resource reads do not accept query parameters. List pages contain up to 25 items, a versioned `contract`, pagination metadata, and navigation links. Follow `page.next_uri` until null. Cursors are scoped to their collection; they are continuation handles, not a stable snapshot of changing data.

Routine instructions, prompt files, the `prompt_agent` tool, and an agent's structured permission requests are different mechanisms from MCP prompts. Consult the generated Prompts section for registered MCP prompt templates and their arguments.
