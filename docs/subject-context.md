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
      id: "travel",
      subject: "Travel",
      path: "/absolute/path/to/travel",
      current_plan: "plans/current.md",
      grants: [
        %{kind: :routine, id: "travel", read_paths: "all"},
        %{
          kind: :sub_agent,
          id: "the-exact-assigned-helper-id",
          read_paths: ["preferences.md", "research/liguria.md"],
          create_paths: ["plans/november-comparison.md"],
          propose_paths: ["preferences.md"],
          proposal_destinations: ["plans/preferences-proposal.md"]
        }
      ]
    }
  ]
```

The human can operate on configured roots. Other identities need an explicit
entry. Read grants may name `"all"`; creation and proposal grants must list exact
relative Markdown paths. Naming a reference, owning a repo or retaining an old
connection does not grant a destination. Helpers also need their recorded spawn and a currently
authorized parent. After helper cleanup, a human or authorized owner still sees
its files and operation receipts. Broad native shell permissions are separate.

Use an existing subject tree with directories such as `research/`, `plans/` and
`decisions/`. A document path is canonical relative Markdown, at most 200 UTF-8
bytes and eight components including the filename. Empty components, traversal,
backslashes, control characters, hidden components including `.git`, symlinks and
nonregular files are refused. Every ancestor is opened without following symlinks
and checked again before returning source or confirming publication. Direct child
paths keep working. The operator creates directories; an exact file destination
grant never implicitly creates a directory or grants other files under it.

Limits are 16 KiB per file, 100 returned file names, 500 scanned entries across
all traversed directories and 100 KiB per search, with a 5-second helper response
timeout. Exact read grants prune ungranted subtrees. A tree exceeding depth or
scan limits refuses explicitly; results are never silently incomplete. Retrieval
may make a one-byte overflow probe; excess content is refused rather than returned.
Missing Python 3 or POSIX descriptor support is an explicit unavailable capability.
An optional absolute `subject_python` setting selects the interpreter. No external
Python packages are needed.

Examples of tool arguments:

```json
{"action":"read","root_id":"travel","path":"preferences.md"}
{"action":"search","root_id":"travel","query":"November"}
{"action":"create","root_id":"travel","path":"plans/november-comparison.md","content":"# Comparison\nSources and uncertainty...\n","request_id":"a-unique-operation-id"}
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
An admitted operation acts on its held original directory descriptors, so a root
or ancestor rename can leave an unconfirmed file in the original directory without
redirecting publication into a replacement. `directory_replaced` refuses a changed
ancestor during an operation. Re-read after reconciling the layout; never claim an
unconfirmed publication as a durable result.

Pull, migrate and restart to install the initial surface. For the recursive-layout
update, pull and restart; no new migration is required. The feature starts with no
roots and no new file authority. Document grants are explicit configuration, not
a change to the held standing shell approval-policy decision.

## Return to a plan and recorded producer

Optional `current_plan` names an existing Markdown document under the same root.
It is a configured reference, not a grant or a claim about a native execution's
plan. A caller sees it only through its current read grant. `return_context` detail
returns that plan's current content revision and a link; human edits change the
next read. No plan is inferred from filenames, a transcript or a helper report.

The folded return context on `/subjects` links to the recorded owner and retains
up to three successful publication references. A publication revision is historical;
it is labelled separately when the current file has changed. Owner navigation
opens the current conversation without relabelling the original producer or
starting/resuming work.

New helper publications capture the exact host-owned retained spawn record.
After cleanup its original parent, brief/result receipts and authored reports
remain inspectable by the human or the currently authorized original parent.
Other document readers receive only the epoch reference and an explicit private
availability state. Helper ids reused later never select the newest worker's
brief/results. Old publications without an epoch, or old registry rows whose
spawn timestamps cannot be matched, remain unavailable rather than guessed.

Previews are limited to three message receipts and two authored reports per epoch,
1,000 UTF-8 bytes per brief/result/report and 64 KiB per navigation projection.
Briefs are parent-authored request excerpts; reports remain authored evidence.
Physical settlement and native publication run attribution are unknown. Tool
payload receipts still describe server emission only; native instruction layers,
model receipt/use and hidden context are not inferred from these links.

Pull and restart for this update. No new migration or prompt change is required.
