# 027: Desktop shell evidence review

Status: review plan for #576, 2026-10-04. No shell implementation.

Review shipped command navigation, desktop/phone notifications and URLs.
Check current primary Safari, Tauri, ElixirKit, Elixir Desktop and LiveView
Native documentation. Record the client/service lifetime contract and a
bounded comparison triggered by two observed unmet daily desktop needs.

Files: this design note. Keep LiveView. No runtime, dependency, service,
prompt, migration or MCP changes, and no invented measurements or shell test.
The actual comparative spike remains outstanding.

Gates before each push: format check, warnings-as-errors compile, strict
Credo, full tests and Dialyzer. No new code or tests in this documentation unit.
