# Current integration-path audit

Run from the Custode project with test queues disabled:

```sh
CUSTODE_TEST_MCP_PORT=6183 mix test spikes/integration_catalog/audit_test.exs
```

The two tests invoke an actual local HTTP MCP tool with separate Snodo clients
and establish that the current temporary-worker config contains only memory,
not the fleet external catalog. They do not launch Claude/Codex or prove that
provider clients load and invoke a catalog entry. The intended adapter proof is
in design/020. No public endpoint, secret, paid run or permission policy is used.
Existing external_mcp_test covers configured tool names and config generation;
neither test group establishes effective provider invocation permissions.
