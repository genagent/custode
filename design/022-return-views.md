# 022: Outputs to return to and context actually supplied

Status: #597 interface design, 2026-10-04. Depends on the narrow document contract
in design/021, not a new context store. Keep agent conversation and direct access;
Custode remains the primary collaborator and owner coordinator.

## Two views

Subject output view lists current useful research, plans, decisions and software
artifacts with title/kind, relative path or verified external link, working revision,
source/date/freshness, recorded producer execution and disposition. A document may
be externally authored with no producer receipt; display that honestly. A PR link
is an artifact reference, not proof of merge/acceptance. Generated index entries
are invalidated/rebuilt against actual source, including uncommitted edits.
A self-authored panel/report is evidence, separate from current document source,
accepted operator decisions, repository state and historical requests.

Run context view lists what this execution actually received: instruction layers
and captured revisions, portable handoff, document/excerpt spans and content hashes,
byte budgets/truncation, provider/configuration/generation/turn/receipt and known
context limits. Archive membership, requested reference and prepared bundle are
not proof a provider received or read the content. Label prepared, delivered and
provider-observed separately; unsupported token accounting remains unknown.
A retrieval result can be recorded as delivered tool content without claiming the
model used it. Native hidden instructions are unknown, not an empty layer.

Record receipts at existing handoff/tool delivery seams, not by scraping old
transcripts. Maintain the exact payload manifest for each run; do not recompute
historical loaded context from today's files. Content revisions are sufficient
for source identity; bounded excerpts or immutable payload references are needed
to inspect old content after external edits. Retain according to documented
limits and show expired content rather than substituting the latest bytes.

## References, navigation and feedback

Named rmcp/research references resolve to identified read sources. Intended output
paths are shown separately and require their own grant. Selecting a document or
helper never starts/resumes it. Open current plan, producing execution, helper
brief/result and return to owner from one detail drawer. Use keyboard focus/Enter
and pointer controls for the same actions; keep long text folded and preserve
open/focus state across LiveView patches. Reuse quiet groups and away digest.

Feedback carries subject/document/revision and a line/span or diff hunk plus
comment. Lines are relative to the selected content revision, not today's line
numbers. A changed revision asks for reread/reanchor; never silently attach to a
different paragraph. Reviewing or approving a prose proposal does not approve a
repository action. Existing document edits use design/021 proposals until safe
apply is implemented.

## Shared surface

Output projection joins configured subject document map/current bytes with durable
output-production references. Context receipt read returns an exact retained run
manifest or an explicit unavailable/expired reason. Proposed read/list/search/
history/diff APIs share design/021's operations and authorization; source edits
remain external-editor compatible. A second search database is not authority.
ToolPolicy and MCP behavior/reference ship with implementation, not this note.

## Return-flow fixtures and limits

Travel fixture in spikes/subject_context: latest comparison is found by current
browse/search, after worker cleanup; a fresh worker reads changed no-car preference
and creates a revision-cited follow-up. No old transcript/session required. Its
synthetic source/date is not real travel research or provider-delivery evidence.

Tower return flow: the output map resolves research/rmcp-update.md to a dated
upstream finding and decisions/pr-review.md to the operator's decision and PR
reference. A fresh bounded read inspects those current files, separately from a
historical self-authored owner report. External edits change the content hash;
feedback bound to the old revision refuses instead of shifting silently. The
same standalone document fixture exercises this flow. Git state and acceptance
still require their authoritative repository/decision sources.

One bounded follow-up composes read-only output/current-plan/helper navigation
and exact loaded-context receipts on existing execution/handoff seams. It uses
production subject operations, not the fixture server. No IDE, native shell,
transcript-mining system or archive-as-loaded-context claim. Default main
conversation remains simple; operational detail stays available.

Implementation follow-up: #785.

## First production slice (#785)

Current output/detail and line-bound feedback use the #784 shared operations.
The `/subjects` view keeps historical producer facts folded beside current bytes.
HTTP subject reads freeze exact tool text and observe only completed JSON server
emission. Client/model receipt, exact native run binding and instruction layers
remain unavailable; an active execution observation is not binding evidence.
Retained payloads expire explicitly. Native delivery and richer navigation remain
on the implementation issue rather than being inferred from archive membership.

## Scoped return navigation (#785)

An optional configured current_plan path names a current subject document, guarded
by the same exact read grant. Detail reads retain its working revision and a link;
this is not an inferred native execution plan. Up to three immutable successful
publication references keep historical source revisions separate from later human
edits and provide recorded-owner links.

New helper publications retain an exact host-owned spawn epoch. Cleanup does not
remove that reference, and reuse of a helper id cannot retarget it. The human or
currently authorized original parent can read bounded parent request/result
excerpts and separately labelled authored reports. Other document readers get an
explicit private state. Missing old epochs stay unavailable. Opening only reads;
no source apply, approval, grant, worker start or resume is added.

Controlled Tower/Travel return tests cover plan edits, exact grants, helper cleanup
and reuse, private results, legacy epochs, authenticated HTTP on both protocols,
and keyboard-accessible owner/plan links. These fixtures are not fresh native
research or instruction delivery proof. Routine HTTP identities still lack a
turn-scoped credential; observed execution snapshots cannot bind a tool call to
one native turn. Native hidden context, model receipt/use and physical settlement
stay unknown. Native acceptance and finer span/hunk review keep #785 open.

## Adapter-entry receipts (#785)

New Claude/Codex run:start observations retain exact inline prompt, system prompt
and appended system prompt arguments, with layer byte counts/hashes and the
durable job, generation, turn, arc, configuration and attempt identity. The
callback arguments must match that exact executing job. This is adapter entry,
not native receipt or proof of model use. File-based instructions, hidden native
context and document-tool-to-turn attribution remain unknown. No historical
backfill uses mutable current files or archived jobs.

The operator-only shared return_context reads and /contexts/:agent_id detail
keep at most128KiB per payload and the newest100 payloads per agent for seven
days. Metadata remains historical; expired, retired or over-budget payloads are
explicit. Context inspection is folded and never resumes work. A running fleet
needs the generated migration and restart to collect future adapter entries.
Native tool-read binding and finer span/hunk feedback keep #785 open.

Run-context payload expiry is logical at seven days, with physical cleanup on
capture, read or list. Inactive records are not subject to a timed erasure job.
Same-execution replay also binds the captured execution identity, including its
configuration revision and correlation, so changed metadata cannot retarget an
earlier receipt.

## Exact span and hunk review (#785)

The shared return_context projection adds optional bounded Git hunks and typed
feedback anchors. Existing inclusive line comments remain compatible. Text spans
use one-based Unicode grapheme columns with an exclusive end and retain exact
selection hash/length plus a byte-bounded preview. Hunk feedback binds current
working revision, pinned HEAD and base/diff fingerprint to one identified hunk.
A changed HEAD refuses even when source bytes are unchanged. Current content
revision match is separate from anchor freshness; unsupported Git labels a
retained hunk unavailable rather than current. Existing comment storage suffices.

Thin keyboard/pointer controls call those shared operations, retain folded detail
and support explicit reread/reanchor. No apply, approval, grants, start/resume,
new store, IDE or native delivery claim is added. Production tests cover Unicode
boundaries, historical selection evidence, exact current grants, both HTTP
protocols, external source/HEAD changes and unchanged source/index/HEAD effects.
Fresh native instruction/handoff delivery acceptance remains separate scope.
