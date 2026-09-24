# 012: The external operator agent

Status: decision note, agreed with the operator on 2026-09-23. Tracking issue:
#647. The first implementation slice is part of that issue; #657 owns exact
message-to-result correlation.

## Purpose

An interactive Claude, Codex, or other MCP-capable session can represent the
human operator to a running Custode instance. It is the preferred first remote
interface: the operator can use a suitable session from another machine while
Custode continues to run on a laptop or server.

The external session is a client of Custode, not another copy of Custode.
Authoritative fleet state, grants, decisions, durable subject knowledge and
work history stay in Custode or the subject's declared context store. A fresh
session must reconstruct useful state through MCP without finding the previous
chat transcript.

## Roles

| Role | Responsibility |
| --- | --- |
| Human operator | Supplies intent, judgment and decisions that require human authority. |
| External operator agent | Maintains the interactive conversation, reads and drives Custode through MCP, and relays questions, decisions and results with provenance. |
| Custode manager | Owns durable fleet state, subjects, policy, backlog, history, planning and delegation. |
| Worker or specialist | Performs bounded work with scoped context, tools, budget and authority, then returns evidence and durable output. |

A conversation with the external agent is not implicit human approval. When it
relays a human decision, the call retains the authenticated operator identity,
target, revision and transport provenance. Autonomous actions remain
distinguishable from relayed human judgment.

## Connection protocol

A newly connected session follows one shared application protocol:

1. Authenticate to the main MCP endpoint and call the versioned operator
   bootstrap operation.
2. Verify the installation identity, Custode version, caller identity,
   effective capability scope and compact current-state counts.
3. Expand only what matters using the existing attention, digest, routine,
   status, gate, ask, spend and feed operations.
4. Submit work or a message to the Custode manager or an allowed routine.
5. Follow the exact submitted request, answer questions and relay explicit
   gate decisions with stable identifiers.
6. Retrieve the durable result and subject output.
7. On reconnect, repeat bootstrap and recover active or completed work from
   Custode-owned records.

The dashboard, CLI, manager and external clients use the same application
operations and central authorization policy. Remote transport may add secure
connection and authentication concerns, but it does not define a second
command set.

## Lifetimes

The external conversation, Custode subject, provider session and worker turn
have separate lifetimes. An external session may disappear at any time.
Operator and specialist provider arcs can resume under design/011, while
scheduled sweeps begin fresh and recover durable context. Provider session
handles are host-local accelerators rather than authoritative history.

Multiple external sessions may also advertise execution capacity. Routing
then chooses a provider, model, effort and execution lane under #575. Work and
personal lanes retain separate credential, policy and context boundaries.

## Bounded implementation

The first slice adds one read-only operator bootstrap operation. It returns a
stable non-secret installation identity, connection identity and transport,
effective authority, configured environment facts and a compact fleet summary.
It points at the existing operations used to expand the brief. It exposes no
credential, Custode home path, prompt text or provider transcript.

The second slice, #657, gives operator messages durable idempotent identities
and correlates them with exact queued, executing, gated and completed provider
turns. #596 remains the broader truthful run and pending-input model. #565 and
#597 own durable subject knowledge and outputs. #653 owns typed Codex session
forking.

The first proof does not require a mobile application, transcript
synchronization, a second orchestrator, general routing or public-internet
exposure.
