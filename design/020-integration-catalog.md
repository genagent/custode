# 020: Shared MCP integrations

Status: #578 design and current-path audit, 2026-10-04. Adopt a logical catalog;
keep provider-native connections initially. No proxy or global protocol session.
Execution-path parity is not present today and belongs to a bounded follow-up.

## Current evidence

MCP.external_servers reads application configuration. Claude routine args include
its generated external config and allowed tool prefixes. Codex routine args
translate HTTP/stdio endpoints into native overrides; SSE is silently omitted and
external allowed tool names are not translated into a central call authorization.
Neither source configuration nor a boot-generated file proves endpoint health,
client loading or an allowed invocation. Whole-server prefixes can grow when a
remote server adds tools.

Sub-agent configuration contains only its identity-scoped memory MCP server;
sub_agent_args receives that file. run_job and workflow node args have no shared
external config. Their workspace may have ambient client configuration, which is
not a controlled catalog path. Codex standing support has shipped; the frozen
Codex kernel is irrelevant. Existing external_mcp_test proves generation only.
The local audit invokes a real fixture HTTP tool through separate Snodo clients;
it does not pretend those clients are Claude/Codex runtime invocations.

## Record and access

Each integration has stable id/revision, display name, HTTP/SSE/stdio transport,
endpoint or launch definition, credential reference, enabled state, audience,
exact intended read tool names, advertised tool/prompt/resource schemas/digest,
and availability/auth observations with timestamps. Distinguish configured,
advertised, allowed, invocable and unsupported. Names are integration-qualified;
collisions fail validation. Secrets stay in credential stores, never prompts,
logs, generated capabilities or inspect responses.

Worker effective config joins integration revision with captured execution role,
provider/client capabilities and explicit access override. Shared package-doc
reads can reach temporary workers without granting fleet lifecycle, writes or
recursive delegation. A tool description is not authority; newly advertised
names are disabled until the allowlist is deliberately updated. Existing broad
prefixes require an explicit compatibility warning during conversion.

Provider-native permissions are an execution constraint, not a central per-call
Custode grant check. Keep GitHub/write-capable native integrations disabled if the
required approved scope cannot be enforced. An explicit broker may later enforce
attributed calls; it is a separate slice, not a convenient grant bypass.

## Application and MCP surface

Proposed shared operations: integration_list/inspect, register/update,
enable/disable, refresh/check and access_update. Mutation requires operator or
existing explicitly authorized manager capability, expected revision and request
id. Discovery is filtered by captured role and audience; denied endpoints/secrets
must not leak. Prompts/resources are cataloged even when a provider client cannot
consume them. Unsupported SSE on Codex becomes a visible reason, not omission.
ToolPolicy and behavior/reference ship with implementation. Current production
MCP advertises none of these new operations.

## Change semantics

Capture catalog/access revision per admitted execution. Updates apply to new
admissions; refresh/reconnect is a provider-specific quiescent operation and cannot
silently alter a live execution's claimed tool contract. Disable blocks new
admissions immediately in application policy. A native in-flight connection may
still exist: state that limitation; urgent revocation requires actual credential
revocation or an enforcing broker, not an edited JSON file. Credential rotation
uses references and reports failed auth without printing values. Availability is
observed per endpoint/client, never globally inferred from one success.

No shared MCP session or stdio process is required. Separate identity/connection
contexts remain separate. A proxy becomes worthwhile only for external-session
access, enforceable invocation policy or managed process reuse with a clear owner.

## Proof and next slice

Use existing Hex/crates identities with local fixture endpoints; no installations
or public calls needed. The audit establishes a working HTTP capability and current
configuration boundaries. A complete adapter proof must launch fake provider
harnesses that load effective catalog config and invoke the read tool for routine,
sub-agent, one-shot and workflow paths, including Codex. Configuration equality
alone fails that acceptance. Until then the decision is no-go for claiming parity.

One implementation slice: effective config on all four paths, a useful catalog
projection, explicit per-worker deny and unsupported-client reasons. Test actual
invocation, unavailable endpoint, expanded catalog, deny, disable/new admission,
in-flight revisions, credential redaction/rotation and absence of lifecycle tools
for temporary readers. Later broker/account integration is independently scoped.
Coordinate generated capabilities #577 through the same filtered discovery.

Implementation follow-up: #782.
