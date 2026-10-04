# Scoped subject documents

The opt-in `subject_context` MCP tool lets an authorized caller recover current
Markdown without recovering a provider transcript. Roots belong to a subject,
not a temporary worker workspace. Notebook state stays in SQLite.

Configure roots in the deployment's normal Elixir application configuration
(for a local source checkout, `config/dev.exs`):

```elixir
config :custode,
  subject_roots: [
    %{
      id: "travel-research",
      subject: "Travel",
      path: "/absolute/path/to/travel/research",
      grants: [
        %{kind: :routine, id: "travel", read_paths: "all"},
        %{
          kind: :sub_agent,
          id: "the-exact-assigned-helper-id",
          read_paths: ["preferences.md", "liguria.md"],
          create_paths: ["november-comparison.md"],
          propose_paths: ["preferences.md"],
          proposal_destinations: ["preferences-proposal.md"]
        }
      ]
    }
  ]
```

The human can operate on configured roots. Other identities need an explicit
entry. Read grants may name `"all"`; creation and proposal grants must list exact
filenames. Naming a reference, owning a repo or retaining an old connection does
not grant a destination. Helpers also need their recorded spawn and a currently
authorized parent. After helper cleanup, a human or authorized owner still sees
its files and operation receipts. Broad native shell permissions are separate.

The current layout is direct child `.md` files only. Use separate roots for
research, plans and decisions. Nested paths, `.git`, hidden files, symlinks and
nonregular files are refused. Limits are 16 KiB per file, 100 returned file names,
500 scanned directory entries and 100 KiB per search, with a 5-second helper
response timeout. Retrieval may make a one-byte overflow probe; excess content
is refused rather than returned. Missing Python 3 or POSIX descriptor support is
an explicit unavailable capability. An optional absolute `subject_python` setting
selects the interpreter. No external Python packages are needed.

Examples of tool arguments:

```json
{"action":"read","root_id":"travel-research","path":"preferences.md"}
{"action":"search","root_id":"travel-research","query":"November"}
{"action":"create","root_id":"travel-research","path":"november-comparison.md","content":"# Comparison\nSources and uncertainty...\n","request_id":"a-unique-operation-id"}
```

Create publishes a new file exclusively; existing files or symlinks refuse. A
proposal needs `path`, `destination`, `expected_revision`, `content` and a fresh
`request_id`. It produces a separate Markdown diff with `applied=false`. It never
changes the source, index or HEAD. History/diff through Git and automatic apply
remain unavailable.

A revision is SHA256 of the bytes returned, independent of HEAD. External editors
and uncommitted changes remain authoritative. A successful create retry returns
the original published receipt, even if someone subsequently edited the file;
use read to inspect current bytes. The receipt retains the authorized producer,
observed execution where available, grant revision and directory identity. It
proves an operation result, not provider delivery or acceptance of the research.

The root's directory identity is retained across restarts. `root_replaced` means
the configured pathname no longer names that identity. Restore the original
directory or deliberately configure a new root id; the service will not silently
rebind an old id. A failed or interrupted mutation may be unconfirmed. Inspect its
receipt and files; do not automatically retry the write under a new operation id.
An admitted operation acts on its held original directory descriptor, so a rename
can leave a file there without making it appear in the replacement directory.

Pull, migrate and restart to install this surface. The feature starts with no
roots and no new file authority. Document grants are explicit configuration, not
a change to the held standing shell approval-policy decision.
