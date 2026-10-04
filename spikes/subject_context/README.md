# Subject context proof

Run from the repository root:

```sh
python3 -m unittest discover -s spikes/subject_context -v
```

Ten tests use synthetic Markdown in temporary Git repositories and a loopback
HTTP MCP tools/call fixture. Two fresh fixture workers retrieve current
preferences/research, write create-only outputs, end, and return via the durable
subject directory. Other tests exercise revision-checked proposals, stale edits,
read-only identity, path limits, bounded retrieval, history/diff and preservation
of unrelated staged/unstaged work. There are no model calls or real travel claims.

This is an application/contract spike, not a deployable MCP server or sandbox.
It implements tools/call only, with fixed test tokens; it does not implement
initialize/discovery, secret provisioning, ToolPolicy, production grants, provider
hooks or hostile-filesystem race protection. Path checks assume a controlled
fixture filesystem; they are not a proof against concurrent symlink replacement.

Existing source files are never overwritten. context_propose checks the current
content revision and writes a separately named proposal with a diff. It returns
applied=false. A hash check plus rename is not filesystem compare-and-swap against
an external editor. context_create uses exclusive creation for a new research
path and refuses an existing destination. No automatic commit or index mutation.

Design/021 records both fulfilled and outstanding live acceptance. Design/022
specifies return views and loaded-context receipts. Do not wire this fixture into
the live tool surface or infer worker file-write authority from it.
