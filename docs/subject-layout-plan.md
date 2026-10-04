# Recursive subject layouts (#784)

Extend the current explicit subject document surface to existing nested Markdown
layouts. Keep roots and current grants authoritative; keep output creation
exclusive and proposals separate from source documents. Traverse each directory
component with held descriptors and refuse symlinks and changed ancestors.

Files: SubjectDocuments path validation and root discovery; the production POSIX
helper; production descriptor race and application/MCP tests; subject context
operator/design documentation and MCP behavior/reference outputs.

Gates: format, warnings-as-errors compile, strict Credo, full tests, Dialyzer;
focused tests under seeds 1, 12345 and 777; descriptor races; MCP docs check;
updated-head public CI before merge.

Out of scope: automatic assignment grants, Git history/diff, creating directories,
automatic source replacement, commits, publication, native provider delivery proof,
notebook migration and kernel changes. This slice keeps #784 open for the remaining
Git and assignment requirements.

Operating note: nested paths become available through existing explicit grants.
Pull and restart. No migration, default roots, prompt change or broader native
shell authority.
