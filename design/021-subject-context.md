# 021: Persistent subject context

Status: #565 bounded spike, 2026-10-04. Adopt the narrow authored-document storage
boundary as a design direction, not a migration. Go for configured context roots,
read/retrieval and create-only outputs; no-go for automatic existing-document
replacement under concurrent external editors. Production operations follow.

## Subject and storage

A subject is the thing the operator returns to. Its configured local context root
is independent of a standing routine, workspace and provider session. A standing
owner is optional; a temporary worker may take a bounded assignment. The root
must survive worker cleanup. Do not create a topics table or permanent Travel
agent just to retrieve a saved comparison. Multiple concurrent owners remain a
reason to revisit identity in design/010, not a prerequisite here.

Authored preferences, research, plans and decisions live in ordinary Markdown in
the Git working tree, including uncommitted edits. Operational conversation,
receipts, jobs, gates, scheduling, spend, notebook records and output-production
references stay in SQLite. journal.md/TODO.md remain generated views. Search and
summaries are derived from content revisions; corrected source wins over stale
memory or summaries. design/002's narrow amendment names this exception.

Suggested map: README.md (scope/document links), context.md (focus),
preferences.md, research/, plans/, decisions/. Source dates, uncertainties and
reasons for decisions belong in documents. A remote and publication are optional
and outside scope. No automatic promotion of tentative research into preferences.

## Existing execution and authority

run_job is the closest bounded execution/return channel; its artifact entries are
unverified paths, parent inbox notes are pruned, and its workspace is not a scoped
subject-write grant. Normal one-shot accept_edits does not restrict filesystem
writes to a configured context root. SubAgents stores a parent-owned multi-turn
spawn/session spec, later replaced by an orphan notice. Neither makes subject
output durable or grants a new document destination by name.

A production read operation validates configured root and caller scope. Human and
captured authorized owner can discover the root; a temporary worker gets only
explicit document references and a bounded destination associated with its
parent/assignment/grant. A reference is not a write permission. File-writing shell
or ambient tools must not be mistaken for enforcement of an MCP destination rule.
New ToolPolicy/grant verbs require implementation review; no standing write grant
is adopted here and #554 is not reopened.

## One operation contract

Proposed shared context_browse/read/search/history/diff, context_create and
context_propose operations serve UI, manager, CLI and external MCP. Inputs use
configured subject id plus relative Markdown path, bounded retrieval options,
expected content revision for proposals and request id for mutations. Never let
a caller choose an arbitrary root or credential path. Results retain path,
working-tree content hash, Git history where present, source/date and producer
execution reference where recorded. Uncommitted source has a content revision
without inventing a commit id. Index invalidation compares actual bytes, not HEAD.

Bound reads (initially 16 KiB/file), bounded result counts/search budgets and
explicit truncation/error prevent loading an entire archive by accident. Refuse
traversal, symlinks and .git access; production confinement must also handle
filesystem replacement races. Git commands use argument arrays, fixed verbs and
path separators; no arbitrary user-supplied Git command or remote operation.

Create writes a new authorized output path exclusively. Existing destination
refuses; no silent overwrite. A proposal checks the revision read by its caller
and saves a separately identified edit/diff, never applying it to the source.
Stale proposal returns current revision for reread/reconciliation. A revision
hash plus atomic rename cannot prevent an uncooperating human editor racing
between check and replacement. Therefore automatic apply remains unavailable
until an enforceable writer protocol or merge mechanism is designed/proved.
Proposals remain current only relative to their captured source; feedback never
retargets automatically when the source changes.

No automatic commit is needed for useful continuity. Preserve the index and
unrelated work. Any later operator commit operation must commit intended changes
without accidentally staging other files; publication is a separate action.

## Executed Travel fixture

spikes/subject_context has ten passing tests. Its HTTP tools/call fixture fixes
identity from the bearer token. Worker one reads preferences and creates dated,
sourced synthetic Liguria research; its temporary workspace is deleted. A human
then changes preferences without a commit. Worker two has a fresh identity and
workspace, browses/searches/reads current files and writes a follow-up citing both
content revisions. Cleanup leaves results discoverable. No transcript or native
provider session is passed.

Read-only caller writes are refused; an invented token gets 401. Traversal and
symlinks are rejected in the controlled fixture. Duplicate destination creation
refuses. Stale proposal preserves a newer uncommitted human correction. A current
proposal returns a useful diff and applied=false. HEAD/index/unrelated unstaged
changes remain exactly unchanged. History and current working diff are distinct.
No live research, paid provider or notebook migration occurred.

## Acceptance accounting

| #565 acceptance | Spike outcome |
|---|---|
| Two temporary workers, durable sourced outputs, cleanup and fresh retrieval | Passed with synthetic HTTP fixture workers |
| Uncommitted human edit and stale-write refusal | Passed for read/proposal; no source replacement |
| Authorized MCP read/edit/diff | Passed tools/call read/proposal/diff; direct apply deliberately rejected |
| Commit preserves unrelated work | No auto commit; index/HEAD/unrelated diff preservation passed |
| Existing notebook behavior | Unchanged production source; full Custode regression gates |
| Actual Custode delegation, production grants, registered tools and output projection | Not implemented; follow-up required |

Close the design spike with this decision and a bounded implementation follow-up,
not a claim that the live Travel flow exists. Production read/create/proposal
operations plus durable assignment/output links come first. Existing-document
apply is separately deferred; no general store, synchronization or kernel revival.

Implementation follow-up: #784.

## First production slice (#784)

SubjectDocuments and subject_context now share current identity and explicit root
and destination grants. They use ordinary Markdown for current source, SQLite
for root identities and immutable operation/producer receipts, and an OTP-owned
optional Python 3 POSIX stdlib port for descriptor-relative filesystem operations.
No Python process is opened until a configured root is accessed. The helper takes
JSON data only and never executes commands or imports caller code.

The first portable boundary is a flat configured root: direct child .md names,
held directory descriptor, no symlinks or nonregular files, bounded reads/search,
exclusive atomic publication with file/directory fsync, and no existing-source
replacement. Separate roots can represent research/plans/decisions. Initial root
binding refuses symlinked directories and mutable parents; only fixed root-owned
macOS /var, /tmp and /etc platform aliases are normalized. Directory identity
persists across helper and application restarts. Replacing the pathname refuses
instead of silently adopting a new directory. Authority is the original directory
identity; rename during an admitted write may leave an unconfirmed file in that
original directory, but cannot redirect it into a replacement root. This is a
protocol destination boundary, not an OS sandbox for an agent's other tools.

Actual descriptor race tests cover root substitution, read-time symlink swaps,
post-open replacement and temporary-file substitution at publication. A changed
publication never becomes a success receipt. A prepared mutation with a lost
receipt never repeats the write. Identical completed requests return historical
published bytes; read always inspects current source, including uncommitted human
corrections. Temporary workers have exact, independently configured grants and
retain output links after their spawn record/workspace is removed.

Git history/diff and automatic apply remain explicitly unavailable. Native
assignment-to-destination provisioning is still manual
operator configuration; no broad write grant or #554 policy posture is selected.
Those parts keep #784 open. #785 may build views over this supported production
surface without pretending the recursive Python spike is the runtime or treating
prepared files as delivered context. Configuration and recovery instructions are
in docs/subject-context.md.

## Recursive production layouts (#784)

The next slice accepts canonical relative Markdown paths in existing subject
subdirectories, up to eight components and 200 UTF-8 bytes. Exact configured read,
create and proposal grants include the full relative path. Every traversed
ancestor is held by descriptor with no symlink following and rechecked for
replacement before returning a read or confirming a publication. Create never
creates directories, replaces source, changes HEAD/index or grants siblings.

Browse/search share the existing limits across the entire traversal: 100 returned
files, 500 scanned entries and 100 KiB of search bytes. Hidden trees and symlinks
are skipped; exact grants prune unrelated subtrees. Depth/scan overflow refuses
explicitly. The operator can use one Travel root for research/plans/decisions
without configuring a separate root for each directory.

Production application and both authenticated Snodo protocol tests cover nested
exact grants, two fresh controlled helper identities, current human edits,
retained output references and stale proposals while preserving HEAD/index and
unrelated staged/unstaged work. Descriptor tests force ancestor swaps at open,
read, browse and publication. These are controlled tests, not a native research
or model-delivery proof. Git history/diff and assignment-scoped grant provisioning
still keep #784 open.

## Scoped Git production reads (#784)

History and current-versus-HEAD diff now share the production exact path grant
and identity checks. Current descriptor-read SHA256 is separate from pinned HEAD
and historical blob identity. History returns bounded path-specific commit ids and
dates without account metadata, never following a rename into an ungranted path.
Diff includes current human/staged/unstaged source while preserving HEAD, index and
unrelated files. These observations confer no source write or acceptance authority.

Small plain local SHA-1 stores use a private no-follow object snapshot, fixed Git
built-ins and no source config/hooks/attributes/remote actions. Copied and expanded
objects, entries, stdout, returned diff/history, caches, CPU and operation time are
bounded. Linked stores, alternates, packed deltas, oversized or malformed stores
refuse explicitly. macOS hard RSS enforcement is unavailable and is not claimed.
Root/metadata/HEAD/source and ancestor races are rechecked before source is emitted.
Production descriptor and authenticated HTTP tests verify current human edits,
exact grants, refusal, retrieval limits and repository state preservation.

Automatic assignment provisioning remains a separate authority design: current
run_job/SubAgents workspace or identity rows do not encode an operator-admitted
exact subject/destination grant. Deriving grants from these would widen authority.
Keep manual configured exact destinations and #784 open for that remainder.


### Admitted helper assignment launches

`subject_assignment` is human-only. Admission requires one existing recorded helper
with a current routine parent, a configured root, its expected configuration revision,
the expected helper record ID, exact Markdown read paths, one create-only destination,
and an expiry of 60 to 3600 seconds. It retains an idempotent operational receipt;
there is at most one pending admission per helper and a hard limit of 1000 retained
admissions. Admission enables no rights on ordinary helper tokens.

Newly started Claude helpers use a host enqueue closure around the existing
`ObanClaude.Agent.Job`. The first eligible durable delivery consumes one admission.
One transaction pins its helper epoch, root revision, generated generation/turn,
correlation, configuration identity, immutable job arguments and admission-message
reference. A separate private configuration carries a subject-only credential.
Only `subject_context` is discoverable through that credential. Every invocation
requires the exact executing first attempt, unchanged job arguments/meta, current
helper epoch and routine parent, unchanged configured root, unexpired admission and
no revocation. Snoozes, retries and terminal executions do not retain authority.
The enqueue callback avoids coordinator calls while a coordinator may be waiting
on the helper; current parent authorization is rechecked before any document right
is exercised. Root descriptor confinement remains the same as ordinary reads.

The assignment destination permits exclusive creation only. Workspace paths,
`accept_edits`, reports and parent requests do not imply root access. No directories
are created in a subject root and no existing-document apply is enabled. Revocation,
terminal adapter events and lazy cleanup remove scoped credentials/configurations;
outputs and producer receipts remain. The persisted `settled` flag only closes
document credentials; it never proves native descendants physically settled.
The original parent execution is unknown
because its ordinary caller credential identifies a routine rather than a turn.
Legacy helper launches, human-parent epochs without typed ownership, and Codex
helper provisioning are outside this initial launch slice. A migration and restart
are required; existing helper launch configurations are unchanged until restarted.
