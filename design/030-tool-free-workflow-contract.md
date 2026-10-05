# 030: Opt-in tool-free workflow execution contract

Status: bounded host-policy implementation, refs #750.

New workflow definitions may explicitly select a versioned tool-free Claude
profile. Existing definitions and already queued jobs keep their current policy.
The profile is captured with the definition and exact stored job inputs, refuses
missing or changed bindings, and pins empty built-in tools, empty strict MCP,
sealed settings, disabled hooks/slash commands, one native turn, the admitted
USD stop and whole-run deadline. Unspecified options cannot widen that profile.

Implementation: lib/custode/workflow.ex, workflow/definition.ex,
workflow/runner.ex, workflow/node_job.ex, workflow/result_contract.ex and a
workflow execution-policy module. Add focused refusal and actual worker-adapter
fixture tests; update retry/reference behavior notes if its returned surface
changes. Preserve historical definition fingerprints for default definitions.

Gates: format, warnings-as-errors compile, strict Credo, full tests and Dialyzer
before every push. New regressions run under seeds 1, 12345 and 777. Independently
review default compatibility, frozen admission and exact wrapper options.

Out of scope: retry admission, enabling the profile in existing catalog entries,
automatic native invocation, process/descendant settlement attestation, hard
token caps, budget reset, runtime migration or a fleet restart. Native CLI
conformance and supported physical settlement still need separate proof; a
host-pinned policy is not sufficient replay authority. #750 stays open.

Operating note: pull and restart loads the new opt-in definition field. No
migration, prompt-file change or existing launch-policy change is planned.

## Implementation boundary

`Workflow.new/3` accepts only nil or the exact profile version. A nil profile
is omitted from the definition snapshot, preserving historical fingerprints.
No built-in catalog entry opts in. New selected jobs omit integration-catalog
configuration and retain the full effective wrapper-option policy and package
versions with their existing result contract. A missing policy, altered stored
options, a changed destination or a changed per-node USD cap fails before launch,
even if a caller rebuilds the job's result-contract map. Unknown wrapper options
are omitted at the query boundary rather than passing through future capabilities.

The same NodeJob and callback/result validation remain in use; accepted sibling
results and the current definition/generation/schema checks are unchanged.
The deadline remains a whole-command timeout, not a descendant containment
receipt. A configured CLI USD stop is not a billing guarantee or a hard token
cap. File artifacts written by the host report subsystem are separate from
native tools. CLI binary resolution and managed/native host policy are not
attested here. Session persistence is disabled only for this opt-in profile;
existing jobs retain their current session-observation path.

Nonpaid tests run the actual NodeJob and released ClaudeWrapper argument builder
with a controlled transport backend. They verify emitted flags, JSON completion,
refused substitutions and immutable result-policy receipts. They make no model
call and establish host behavior only. Retry remains unavailable for both profiles
until native conformance, supported physical settlement, cumulative admission
and explicit replay rules are proved.
