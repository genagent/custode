# The test database persists across runs (the app boots it before this file
# runs), so truncate everything for hermetic runs -- the earlier "passes
# alone, fails on the third run" class of flake came from exactly this.
Custode.Repo.query!("UPDATE work_items SET parent_id = NULL")
Custode.Repo.query!("DELETE FROM workflow_node_results")
Custode.Repo.query!("DELETE FROM workflow_runs")
Custode.Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
Custode.Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")

for table <- [
      "oban_jobs",
      "journal_entries",
      "todos",
      "memories",
      "spend",
      "gates",
      "gate_reviews",
      "next_beats",
      "inbox_wakes",
      "agent_handoff_intents",
      "agent_authorization_snapshots",
      "conversation_arc_events",
      "conversation_arcs",
      "operator_messages",
      "helper_records",
      "integration_overrides",
      "integration_requests",
      "route_decisions",
      "owner_reviews",
      "subject_root_bindings",
      "subject_document_operations",
      "peer_messages",
      "disowned_prs",
      "asks",
      "observations",
      "feed_entries",
      "issue_drafts",
      "instance",
      "work_events",
      "work_gates",
      "attempts",
      "context_bundles",
      "artifacts",
      "work_items",
      "operation_calls",
      "role_bindings",
      "legacy_routine_mission_mappings",
      "mission_targets",
      "missions"
    ] do
  Custode.Repo.query!("DELETE FROM #{table}")
end

ExUnit.start(exclude: [preview: true])
