# Scoped subject Git reads (#784)

Add production history and current-versus-HEAD diff to the shared subject_context
application operation. Both require current identity and the existing exact path
read grant. Retain current descriptor-read content revision separately from pinned
Git HEAD/blob revision. History stays on the authorized path and never follows
renames into old ungranted paths. Return commit ids and dates without account data.

Use a bounded no-follow snapshot of a plain local repository's object store in a
private temporary bare directory. Do not discover parent repositories, resolve
linked gitfiles, use alternates, load repository configuration or run plugin code.
Git receives fixed argv, a minimal environment, no shell, external diff, textconv,
hooks or remote actions. Bound metadata/object bytes, entry count, decompressed
output, process memory/CPU/time and returned history/diff. Missing Git and unsupported
stores fail explicitly. Recheck root, Git metadata and current file identities;
never confirm a read after a replacement race. Preserve HEAD, index and unrelated
staged/unstaged files byte-for-byte.

Likely files: SubjectDocuments, descriptor helper, production descriptor tests,
application/HTTP tests, ToolPolicy review, MCP behavior/generated references,
docs/subject-context.md and design/021. Existing history/diff action names retain
strict schemas; no arbitrary ref, path root, Git command or pagination expression.

Before every push run format, compile with warnings as errors, strict Credo,
full tests and Dialyzer. Verify focused tests under seeds 1, 12345 and 777, generated
MCP references, deterministic metadata/object/root/ancestor race regressions and
real authenticated Snodo clients. Use work-3 database, port 6183 and isolated TMPDIR.

Operating note: pull and restart. No migration or prompt changes planned. Read
references grant no writes. Ordinary software linked worktrees and large stores
are outside this bounded first Git slice. No apply, staging, commit, publication,
provider/session attribution or automatic assignment-to-destination provisioning.
Assess provisioning separately before any authority extension. #784 stays open
while assignment-scoped grant provisioning remains manual.
