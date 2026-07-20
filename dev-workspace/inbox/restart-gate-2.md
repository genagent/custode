FILED 2026-07-20

RESTART NOTICE: before the last restart you had a pending approval:

In lib/custode/feed.ex, add simple rotation to Custode.Feed.write/2: when feed.jsonl exceeds a size threshold (e.g. 1MB), truncate it to the last N lines before appending, closing the ROADMAP Tier 2 "feed.jsonl grows forever" item.

If it is still relevant, re-raise it on this sweep
(directive=request_permission or directive=ask_user). If it is moot,
just journal that and move on.
