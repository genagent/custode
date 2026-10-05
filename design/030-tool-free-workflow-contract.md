# 030: Opt-in tool-free workflow execution contract

Status: implementation plan, refs #750.

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
