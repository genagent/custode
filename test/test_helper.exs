# The test database persists across runs (the app boots it before this file
# runs), so truncate everything for hermetic runs -- the earlier "passes
# alone, fails on the third run" class of flake came from exactly this.
for table <- [
      "oban_jobs",
      "journal_entries",
      "todos",
      "memories",
      "spend",
      "gates",
      "feed_entries",
      "issue_drafts",
      "instance"
    ] do
  Custode.Repo.query!("DELETE FROM #{table}")
end

ExUnit.start()
