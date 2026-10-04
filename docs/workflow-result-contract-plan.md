# Workflow result binding prerequisite, #750

New workflow NodeJob admissions retain a versioned digest of all stored launch arguments, the pinned worker policy, captured definition, rendered input identity and result schema. The actual callback transaction checks those bindings before accepting a result and validates structured output against the frozen schema using an explicitly supported JSON Schema subset. Unsupported assertion keywords stay unavailable, never silently validated. First accepted results remain immutable. Missing, changed or malformed bindings refuse without replacing historical results or advancing a run.

Persist a nullable validation receipt on workflow_node_results with the callback job/generation identity, input/schema/definition digests and validation outcome. Legacy jobs and rows remain explicitly unbound and retain their existing completion behavior. A new bound job with invalid structured output fails its current stage rather than supplying schema-invalid data downstream. Callback metadata remains observed host evidence, not native provider receipt or physical settlement.

Files: lib/custode/workflow/{runner,node_job,results,retry_status}.ex, a shared result-contract module, one generated migration, workflow tests, design/015-workflow-retry.md and maintained MCP behavior/reference files. RetryStatus reports bounded validated versus unbound results through its existing shared MCP/CLI/UI read, while retaining retry_offered=false.

Validation: all five repository gates before every push; focused callback/runner/result/retry tests under seeds 1, 12345 and 777; changed stored args and schema, malformed and absent contract, stale generation, duplicate/conflicting callback, invalid output, accepted-result preservation and legacy compatibility. Test runs use isolated work2 DB, port6182 and private TMPDIR. No paid providers.

Out of scope: retry enqueue/admission, automatic replay, new scheduler, native effect confinement, all-descendant physical settlement, budget resets, new workflow grants, or claims that terminal Oban jobs prove process death. #750 remains open for safe retry.

Operating note: adds a nullable result-validation column and changes completion admission only for newly bound workflow jobs. Pull, migrate and restart. Already queued legacy jobs retain their prior behavior and cannot acquire missing historical launch evidence retroactively. No prompt file changes.
