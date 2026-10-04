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
