# 025: Missions protocol review

Status: review plan for #459, 2026-10-04. No implementation decision yet.

Review the current project manager, routines, inbox, notebook, workflows and
frozen Mission records against design/009's labelled-backlog benchmark.
Record the smallest useful objective/assignment/result protocol, who owns
completion, restart recovery, the evidence required to justify more machinery,
and whether the existing workflow runner or Mission tables earn a role.

Files: this design note and a cross-reference in design/010. No runtime,
configuration, prompt, migration or MCP changes. Keep kernel intake frozen;
#554 and #555 remain operator decisions. A real comparative delivery proof
will be recorded as outstanding if repository inspection cannot establish it.

Gates before each push: format check, warnings-as-errors compile, strict
Credo, full tests and Dialyzer. No new code or tests in this documentation unit.
