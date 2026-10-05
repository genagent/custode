# 032: Historical output provenance navigation

Status: planned bounded return-view slice, refs #785.

Admitted helper publications retain their parent and helper epoch inside an
assignment execution binding. Return navigation must read that recorded binding,
keep the original epoch after helper cleanup/reuse, and preserve current access
checks. Operator output detail should link to the exact retained producing run
context when its complete execution and assignment binding match. It must not
infer a turn from the latest agent state or claim context receipt/model use.

Historical context links address immutable receipt ids. Their availability must
not depend on inclusion in a newest-100 listing. Read the exact receipt through
the existing shared authorization, verify its agent or root matches the route,
and retain payload expiry and unavailable states. Listing caps stay unchanged.

Files: ReturnNavigation, shared run-context lookup, run/subject context LiveViews,
focused regression fixtures and MCP behavior/reference documentation. No new
write, grant, provider execution, retention extension, migration or scheduler.
Opening links never starts work. Native consumption acceptance remains separate.

Gates: all five checks before each push, focused seeds 1/12345/777, independent
review and exact updated-head CI before merge. Preserve unrelated worktrees.

Operating note: pull and restart loads the projection and historical-link fixes.
No migration, prompt change or expansion of authority.
