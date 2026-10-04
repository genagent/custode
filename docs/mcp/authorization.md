# MCP authorization model

This document records Custode's MCP authorization surface as of 2026-09-23.
It distinguishes intended authority from current enforcement so clients and
maintainers do not mistake discovery metadata or a generated allowlist for an
access-control boundary. The generated [client reference](../mcp-reference.md)
remains the source for each operation's arguments, effects, and implemented
checks.

This is a design audit. It does not enable new enforcement.

## Four separate layers

Every MCP call passes through four layers. They currently answer different
questions:

1. **Identity authentication** verifies a per-boot bearer token and attaches an
   operator, routine, or sub-agent identity to the request.
2. **Endpoint registration** determines which capabilities a server advertises.
   The main endpoint registers the complete tool surface and operator resources.
   The memory endpoint registers four memory and notebook tools.
3. **Client exposure** determines which registered tools Custode places in a
   routine's generated MCP allowlist. It guides the normal client, but a caller
   can construct a request for a tool that is absent from that allowlist.
4. **Runtime authorization** is a check inside a tool handler or the shared
   operation that performs the action. Only this layer refuses a direct call.

`Custode.MCP.ToolPolicy` describes the intended category of every tool. Runtime
code does not read that module, so it is documentation and coverage metadata,
not an enforcement mechanism.

## Identities and intended endpoints

| Identity | Main endpoint | Memory endpoint | Normal client exposure |
| --- | --- | --- | --- |
| Human operator | Full operator surface | Refused | All tools and operator resources |
| Caretaker routine | Yes | Refused | Worker tools plus a bounded operator bundle and roster/profile management |
| Specialist routine | Yes | Refused | Worker tools |
| Temporary sub-agent | No | Yes | `journal_read`, `remember`, `recall`, and `forget` |

The router enforces endpoint membership. The server filters main-endpoint tool
discovery by current routine role and refuses a direct call outside the same
capability set before dispatch. The caretaker can explicitly discover several
low-frequency fleet reads and owned-checkout operations that remain absent from
its compact provider allowlist.

Main-endpoint resources are a separate surface. Their list and read operations
are restricted to the human operator at runtime. Routine and sub-agent callers
receive no resource inventory and cannot read a resource by guessing its URI.

## Intended role capabilities

The table groups tools by authority rather than listing their schemas. `Own`
means the authenticated agent may target only its own durable state. `Child`
means a routine may target only a temporary agent it started. `Served` means the
repository must be configured in Custode and the action remains subject to its
policy and grant rules.

| Capability | Operator | Caretaker | Specialist | Temporary agent |
| --- | --- | --- | --- | --- |
| Fleet, attention, usage, and lifecycle reads | Yes | Yes | As exposed | No |
| Read another agent's todo, inbox, or recalled memory | Yes | Yes | Yes | Yes through `recall` |
| Read project progress and direct operator exchanges | Yes | Yes | No | No |
| Read a journal | Any target | Own | Own | Own |
| Write journal, todo, and memory records | Any target | Own | Own | Own |
| Ask the operator | No personal target | Own | Own | Own |
| Answer or dismiss an operator ask | Yes | No | No | No |
| Read peer messages | All exchanges | Own exchanges | Own exchanges | No |
| Send or reply to peer messages | No | Own identity | Own identity | No |
| Acknowledge a peer message | No | Received messages | Received messages | No |
| Beat, note, pause, or resume a routine | Yes | Yes | No | No |
| Set operator presence or drain the fleet | Yes | No | No | No |
| Read served repositories and local facts | Yes | Yes | Yes | No |
| Change served repositories | Yes | With an applicable approved grant | With an applicable approved grant | No |
| Start and manage temporary agents | Yes | Child | Child | No |
| Approve or reject a sibling routine's gate | Yes | No | No | No |
| Manage the roster and profiles | Yes | Approved caretaker continuation | No | No |
| Provision or refresh a routine-owned checkout | Yes | Yes | No | No |
| Run an arbitrary job | Yes | Scoped continuation only | Scoped continuation only | No |

Cross-agent reads by `recall`, `todo_list`, and ordinary `inbox_list` notes are deliberate.
They make durable fleet context transparent while journal and all notebook or
memory writes remain self-scoped. This choice requires callers to keep secrets
out of shared agent memory; issue #597 covers the broader context-store trust
model.

Peer inbox projections retain the participant-only read boundary of their
durable envelopes. The older inbox tools filter them for unrelated readers and
require the authenticated recipient before filing, even for an operator caller.
`drop_note` cannot write reserved peer projection filenames. These exceptions
preserve ordinary-note transparency without exposing peer bodies or letting
another caller manufacture the recipient's acknowledgment.

`project_progress` is the explicit coordination read for the human operator and
caretaker. It includes a configured project's current execution and blockers,
continuity, pending input, and bounded pages of full direct-operator exchanges.
The shared service checks the caretaker role captured by the active execution
contract. The handler requires verified request identity and never falls back
to an implicit operator. Specialists and temporary agents cannot invoke it,
even for their own routine. Reading changes no message receipt or work state.

This view preserves operator constraints and message IDs so a manager can
refresh evidence before coordinating. It does not grant sibling lifecycle,
prompt, history, await, or gate-control access. Peer-message bodies remain
participant-scoped. Page cursors retain the conversation row watermark; omit
the cursor to observe the latest operator conversation before a new decision.

The caretaker operates the fleet but does not judge sibling work. Its bounded
operator bundle exists to wake, pause, resume, inspect, and maintain agents.
Only the human operator may decide another routine's approval gate. This
restriction applies even when the caretaker's role grants operator-tier shared
operations elsewhere.

Peer messaging is a separate `peer_message` policy category, not delegation.
`peer_send` and `peer_reply` derive the sender from verified authentication;
replies also derive their recipient and correlation from the original message.
`peer_read` and `peer_list` are inert participant-scoped reads, with fleet-wide
visibility for the human operator. `peer_ack` records receipt only and is
restricted to the recipient. Operators can inspect an exchange but cannot
impersonate either routine by sending or acknowledging it. The normal worker
bundle includes all five tools, so Claude and Codex routines use the same
service and authority checks.

A peer message is untrusted evidence or a request. It cannot approve a gate,
grant a tool, change a role or override an operator constraint. The recipient
decides whether and how to act under its existing rules. Durable acceptance,
inbox delivery and acknowledgment do not establish that any requested work
was completed.

## Current runtime enforcement

The current handlers enforce these boundaries:

- Every HTTP request must carry a valid bearer token.
- The main endpoint admits operators and routines; the memory endpoint admits
  only temporary agents.
- Main-endpoint discovery and blind calls enforce operator, caretaker, and
  specialist capability sets. Refusals record token-free caller, endpoint,
  capability, and reason metadata.
- Notebook and memory writes, journal reads, and operator asks are self-scoped
  for agent identities. The human operator may provide an explicit target.
- Answering and dismissing asks, changing operator presence, and draining the
  fleet require the human operator identity in the handler or shared action.
- Roster and profile writes require the human operator or a caretaker whose
  live human-approved continuation has action class `roster`.
- Beat, note, pause, and resume use shared operator authorization. They accept
  the human operator and the current caretaker, and refuse specialists and
  temporary agents before changing state. Owned-checkout operations use the
  registered operation authorization with the same role boundary.
- A routine cannot approve or reject a configured routine's gate. This is the
  mechanical sibling-judgment boundary described by the operated-fleet design.
- Delegated-agent lifecycle, prompts, history, and gate decisions verify the
  durable parent record. Missing or reconciled records deny routine access;
  the human operator retains an override.
- One-shot jobs bind a routine to its configured working directory or owned
  checkout and its own notebook inbox. Elevated jobs require the human
  operator or a live approved continuation whose action class permits shell
  work.
- Disown and reclaim operations require a served repository. Routines act
  only on the repository in their roster entry and may revise only records
  they own; the human operator retains an explicit override.
- Repository writes check served-repository policy. Agent writes also pass
  through the action-grant check, whose default mode currently observes and
  records an out-of-grant call rather than refusing it.
- Main-endpoint resources require the human operator identity.

The repository grant checker still defaults to observation. Turning refusal
on is the policy decision tracked by #554.

This remaining gap matters even when Claude Code or Codex honors its generated
allowlist. Custode is intentionally MCP-native, so external sessions, command
line clients, and future model providers must receive the same server-side
decision from the same authenticated request.

## Target architecture

Custode derives endpoint admission, discovery, generated client allowlists, and
call-time role authorization from one executable capability policy. Narrower
operation authorization should continue to use this context:

- authenticated identity kind and current routine role;
- endpoint kind;
- target identity and, for temporary agents, recorded parent;
- served repository and caller-owned workspace;
- active approved continuation or action grant when the operation requires
  one;
- tool-specific policy that cannot be represented by a broad role grant.

The server denies a blind call before the handler performs work. Shared
operator operations must retain their own authorization checks because the
dashboard, CLI, console, and future transports also call them. Client allowlists
remain useful as a compact user experience and least-context mechanism, but
they become a projection of the server policy rather than its substitute.

Refusals should identify the violated boundary without exposing tokens or
private records. The audit trail should record the caller, capability, target,
and refusal reason.

## Bounded implementation slices

The following work can proceed without resolving the deferred autonomy
policy:

1. #638 enforces endpoint identity membership and central role capability
   checks at the MCP boundary, with blind-call tests for every identity at both
   endpoints.
2. #639 enforces parent ownership for temporary-agent lifecycle, prompts,
   history, and gate decisions while keeping the human operator override.
3. #640 moves fleet-control and roster/profile restrictions into shared
   operations, including proof of an approved caretaker continuation for
   configuration writes.
4. #641 scopes `run_job`, repository local facts, disown/reclaim operations,
   and reporting paths to the authenticated caller and its approved workspace.

Three choices remain outside this audit:

- #554 decides when repository grant observation becomes refusal and which
  action classes may receive autonomous approval.
- #555 decides the final classification of issue-marker operations.
- Any broader caretaker approval or sibling-control authority remains separate
  from #451's bounded project-manager coordination read.

Implementation should add adversarial tests at the HTTP boundary. Each test
must initialize a real session with an identity token, invoke a known tool by
name even when it is absent from that identity's normal allowlist, and assert
both the refusal and absence of side effects. Handler-level tests remain useful
for target ownership and shared-operation invariants.
