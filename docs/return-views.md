# Current outputs and historical context

Open `/subjects` or follow Outputs from an agent conversation. Configured roots
use `subject_context` authority, including external uncommitted edits. The shared
`return_context` tool lists current outputs, opens detail, reads historical tool
receipts and records revision-bound line, text-span and Git-hunk comments. Opening does not launch work.

Production receipts are historical and can survive helper cleanup. They do not
establish document acceptance, live repository state or provider delivery. Current
root and path grants still apply to historical reads. Private tool payloads belong
to the authenticated requesting actor or the human, not every peer with a root grant.

Only subject document reads made through the HTTP MCP endpoint currently create
context receipts. A receipt freezes the exact JSON tool text, content hash and
working revision before response preparation. A matching completed JSON send marks
`server_emitted`. A chunked response, interrupted send or missed persistence stays
`prepared`, not falsely delivered. Client receipt and model use remain unknown.
Standing native instruction layers, provider-hidden context and exact run/session
binding are unavailable on this seam. An observed execution snapshot is not that
binding. Direct shared-operation calls do not fabricate HTTP delivery receipts.

Payloads are retained for seven days and at most 100 payloads per actor. Later
preparation retires excess payloads. Reads label expired payloads explicitly and
never replace them with current file bytes. Metadata remains for audit. Old payloads
may contain private documents, under the same database protections as notebook data.

Feedback binds the observed working revision and inclusive line span. It refuses a
changed revision and requires reread/reanchor. A concurrent external edit after
that read may make the retained comment historical; the comment never alters source
bytes. Feedback is not repository approval or automatic proposal apply.

Remaining #785 scope includes proven native instruction/handoff delivery and run
binding. Current plan/helper/owner navigation and scoped span/hunk review are
shipped. Unsupported evidence stays explicit. Pull, migrate and restart for the
original receipt tables; this feedback refinement needs no additional migration.

## Exact feedback anchors

Existing start_line/end_line comments keep their inclusive line semantics. The
optional anchor object replaces those top-level fields. Its kind is lines, span
or diff_hunk; extra or mixed selection fields refuse. All selectors still require
expected_revision, root_id, path, comment and request_id, and the current exact
path read grant. Idempotent retries retain the same comment; changed arguments
with the same request id refuse.

A span carries start_line, start_column, end_line and end_column. Lines and
columns are one based; columns count Unicode graphemes, including a combined emoji
or accented character as one. The end is exclusive. The column after a line's
last grapheme is valid. Cross-line selections retain the intervening newline;
LF and CRLF separators preserve exact selected bytes without adding a column; empty, reversed and out-of-range selections refuse. Whole-line selections include
separators between the selected inclusive lines.

Read return_context action diff for a bounded read-only hunk projection. It shares
subject_context Git confinement and exact grants. The result carries current
working revision, pinned git_revision (null for unborn HEAD), diff_revision and
at most 100 hunks with hunk_id, header, text and old/new ranges. has_more_hunks
labels the bound; further hunks are not reviewable in this slice. No Git capability
is inferred when the underlying bounded store is unsupported.

A diff_hunk anchor copies expected_git_revision, expected_diff_revision and
hunk_id from that projection. Feedback re-reads the current scoped diff before
admission. An external content edit or changed HEAD requires reread/reanchor;
a new unrelated commit also changes the hunk identity even if the diff text is
unchanged. No arbitrary ref, repository command, apply, approval or resume exists.

Comments retain full selection SHA256 and byte length, plus at most 1024 UTF-8
bytes of preview on grapheme boundaries. Larger selections explicitly truncate;
a single oversized grapheme may yield an empty preview. These retained excerpts
live with the existing comment records under current document read grants. Detail
labels anchor_state as current, historical or current_diff_unavailable separately
from matches_current_revision; missing Git cannot turn a retained hunk current.

The subject detail offers ordinary keyboard/pointer form controls for the same
shared operations, a folded hunk view and an explicit reread button. A successful comment refreshes the shared detail, displays its observed revision, rotates its request id and resets the composer, allowing a second comment in the same view without duplicate text. Opening or
commenting never resumes work. Pull and restart; no migration or prompt change.
