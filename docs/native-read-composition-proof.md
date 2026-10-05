# Native read-composition proof, 2026-10-04

Status: bounded evidence for #799; dynamic catalog acceptance remains open.
The native CLI processes called an isolated real Custode/Snodo HTTP endpoint.
Repository operations returned a controlled fixture, not live GitHub data.
Discovery was narrowed to four existing compiled tools by a measurement proxy;
this is not the full production catalog or a dynamic catalog implementation.

## Observed

| Client | Scenario | MCP calls | Backend reads | Returned text bytes | Run/capture ms |
|---|---|---:|---:|---:|---:|
| Claude 2.1.284 | Three original reads | 3 | 3 | 233 | 6172 |
| Claude 2.1.284 | Composition | 1 | 3 | 461 | 5930 |
| Claude 2.1.284 | Partial failure | 1 | 2 | 343 | 6958 |
| Claude 2.1.284 | Denied repository | 1 | 0 | 44 | 4821 |
| Codex 0.157.1 | Three original reads | 3 | 3 | 233 | 14599 |
| Codex 0.157.1 | Composition | 1 | 3 | 461 | 11458 |
| Codex 0.157.1 | Partial failure | 1 | 2 | 343 | 12415 |
| Codex 0.157.1 | Denied repository | 1 | 0 | 44 | 11601 |

Claude emitted `claude-sonnet-5-5`. Codex was explicitly requested with
`gpt-5.5` at low effort; its emitted stream did not identify the actual model.
Both negotiated `2025-06-18`. Each successful comparison returned the old PR
head and different checks reference, and its final text mentioned both and
the mismatch. That is a bounded lexical check, not a general quality score.
The unpinned-diff lexical marker was absent in Claude summaries; no stronger
interpretation claim is made. Partial results retained the first read and its
exact composition trace, without running the third read. Denial ran no
repository operation. Trace revisions and actors match the retained manifest.

The demonstrated saving is two MCP calls per composition invocation. Backend
work is unchanged, and returned text grows with trace/consistency metadata.
One observation per case, different caches and prompts, and a separate Codex
original-read run do not establish a token, cost or latency improvement.
Returned bytes are not proof of model consumption. Native usage and cost remain in private originals. The public projection omits
account metadata and retains stable SHA-256 aliases for native sessions.

## Failures and corrections

The first Codex launch with `gpt-6.1-sol` returned an account/model rejection
before any MCP calls. Its native failed terminal and session identity remain
in the evidence. The next original-read run completed without calls because
the prompt prohibited native discovery of deferred tools. Allowing native
discovery fixed that case; only that case was rerun. There were no interactive
corrections within a run, but these two harness corrections are part of the
experiment, not zero operator effort.

[OpenAI's model documentation](https://learn.chatgpt.com/docs/models) lists
model availability as dependent on account/client rollout and lists GPT-5.5
until October 14, 2026. It is an explicitly selected experimental fallback,
not a new default or a durable availability guarantee. The harness permits an
explicit model override and stops on failed client startup.

## Retention and reproduction

`spikes/capabilities/native-composition-results.json` retains eight successful
case measurements plus both failed attempts. It includes stable native-session SHA-256 aliases, CLI versions,
requested/observed models, caller/definition/source
revisions, SHA-256 hashes reconstructed from the recorded harness and composition source snapshots,
actual tool-call observations and recorder-held trace references. Recorded
source revisions precede integration rebases; the file hashes identify those
snapshots independently of the later branch history.

Raw native streams stay in private local temporary files with mode 0600.
Bearer tokens and private client configuration are removed after the test;
neither appears in the committed report. The ordinary CI test executes seven
nonpaid parser checks, and excludes the native test with `preview: true`.
A deliberate paid reproduction uses:

```sh
TMPDIR=/private/tmp/custode-native-proof \
CUSTODE_TEST_MCP_PORT=6183 \
CUSTODE_NATIVE_COMPOSITION_PROOF=1 \
CUSTODE_NATIVE_COMPOSITION_REPORT=/private/tmp/native-composition.json \
CUSTODE_NATIVE_CODEX_MODEL='<available native model>' \
mix test test/custode/native_composition_test.exs --include preview --seed 1
```

Create the private TMPDIR first, keep it separate from another worktree's
fixtures, and observe the repository's same-instance boot cooldown. Optional
`CUSTODE_NATIVE_COMPOSITION_PROVIDERS` and
`CUSTODE_NATIVE_COMPOSITION_SCENARIOS` select comma-separated cases. Native
runs have a 90-second deadline, bounded captured output, no file/shell work,
and a four-tool catalog. Claude requests a 0.60 USD stop and five-turn limit;
Codex has no demonstrated dollar stop. Process-group return does not attest
that every possible escaped descendant is gone and confers no retry authority.

## Nonpaid protocol compatibility follow-up

The controlled `MCPCatalogCompatibilityTest` uses real loopback HTTP and pinned
Snodo 0.4.1, with synthetic caller credentials and read-only fixture components.
All three configured dialects list tools, prompts and resources, preserve the
caller at invocation, hide denied catalogs and refuse guessed denied invocations.
The test deliberately replaces an immutable runtime; subsequent explicit reads
and fresh reconnects see v2 while the captured v1 router remains unchanged.
This replacement seam is test-only, not a production publication service.

A 2026-07-28-only runtime with a configured source delivers tools/prompts/resources
list-change events over a real HTTP subscription. Pinned Snodo refuses those
`listChanged=true` surfaces when either initialize-era dialect is enabled, and
legacy `subscriptions/listen` is unsupported. Current Custode config supplies no
subscription source and advertises no list-change capability. Protocol-level
notification definitions in the [2025-11-25 tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
do not establish implementation or native-host support.

Installed nonpaid host observations are retained separately in
`spikes/capabilities/catalog-compatibility-results.json`. Codex 0.157.1's
`mcpServerStatus/list` exposes changed tools/resources without starting a thread
or turn. Every status lookup makes another initialize request, so even a second
lookup in the same app-server process proves fresh discovery, not held-connection
refresh. A new app-server process rediscovers v2. Its status API does not expose
prompt inventory. Claude 2.1.284's isolated `mcp list` health check connects on both
fixture revisions; its output does not expose catalog contents. No inference,
account metadata or raw native session identifiers are part of this follow-up.

Reproduce the explicitly nonpaid observation after creating a private TMPDIR:

```sh
TMPDIR=/private/tmp/custode-catalog-proof \
CUSTODE_TEST_MCP_PORT=6184 \
CUSTODE_NONPAID_CATALOG_PROOF=1 \
CUSTODE_NONPAID_CATALOG_REPORT=/private/tmp/catalog-proof.json \
mix test test/custode/mcp_catalog_compatibility_test.exs --include preview --seed 1
```

Ordinary CI covers the controlled protocol cases but excludes the installed-host
probe. The script permits only app-server initialize/status methods and MCP
configuration/health commands; no thread or turn method is sent. Child native
configuration lives in a private temporary directory and is removed afterward.
Process-group cleanup does not attest all escaped descendants settled.

## Remaining #799 acceptance

Actual Claude catalog-content changes, native prompt discovery, long-lived native
notification handling and refresh remain unknown. Fresh discovery/reconnect is
bounded evidence, not complete dynamic-catalog acceptance. Keep individual dynamic
entries disabled; the fixed dispatcher does not require them. This follow-up
expands no activation, provider authority, automatic mining or effect admission.

## Retained-output semantic review

A later review checked the meaning of the eight retained final answers, rather
than treating words such as `differ` or `not bound` as a quality score. Seven
answers met the controlled case rubric. The Codex partial-failure answer
compared the composition definition revision with the single returned PR head
and said they differed. Those identifiers describe different things; the missing
checks read supplied no second repository head to compare. That answer requires
a correction. No corrective native run was performed.

This review is a case-specific assessment by the interactive reviewer, not an
independent statistical evaluation of either provider. The detailed assessments
and raw-capture bindings remain private. Native session identifiers, capture
hashes and account telemetry are not added to this public follow-up.

The useful rubric is:

- Compare repository heads only from the PR head and checks SHA fields.
- Treat the composition revision as the definition's identity.
- A partial result with only one head cannot establish whether two heads differ.
- Denial supplies no usable repository evidence.
- Successful reads still leave the diff binding and atomic snapshot unavailable.

The original lexical markers remain historical observations. They cannot
establish correctness: a partial answer can contain a mismatch word while
comparing the wrong identifiers, and correct prose can describe an unbound diff
without using one of the selected keywords. The demonstrated two-call saving
remains valid. General token, latency, cost and quality benefit remain unproven.
Keep the existing explicit owner opt-in; these results do not justify expanding
activation or publishing individual dynamic entries.


## OS-process reconstruction

The opt-in nonpaid `mix custode.composition.proof` task passed `init`, `reopen`
and `final` in three separate OS processes over one private isolated test store.
It exercises the actual `ReadCompositions` implementation and fixed MCP dispatcher
through authenticated Snodo HTTP, using controlled backend reads. It publishes
two immutable definitions, activates the first, reconstructs it, replaces it,
disables it, rolls back, and reconstructs the restored activation. The final
generation is four. A valid peer credential is denied without backend reads;
retained traces identify the original caller and three underlying operations.
No model is launched, and executable queues and schedulers are disabled.

Private manifests and source copies bind every phase to the same exact source
files and lockfile. The recorded checkout commit precedes the uncommitted proof
implementation; the file hashes and copies bind the executed source. These are
process-reconstruction results, not evidence that a held Claude or Codex session
received changed catalogs or prompts. No native identifiers, private capture
hashes, account data or raw answers are added to this public report.

To reproduce, use a private `TMPDIR`, an isolated test MCP port and a fresh direct
child root, then invoke each phase in a separate OS process. Observe the normal
instance-start cooldown between phases. Never use the fleet checkout or store.

```sh
MIX_ENV=test CUSTODE_COMPOSITION_RESTART_PROOF=1 \
TMPDIR=/private/tmp/custode-composition-proof CUSTODE_TEST_MCP_PORT=6185 \
mix custode.composition.proof --root /private/tmp/custode-composition-proof/run --phase init
```

Repeat the command with `--phase reopen`, then `--phase final`. Each phase refuses
an unsuitable root, environment or missing opt-in. Existing private recorded roots
are required after initialization, and exact source bindings must still match.

## First-proof decision for #577

Retain the fixed dispatcher behind explicit owner activation. It meets the
bounded design spike's typed, caller-scoped read composition and lifecycle
requirements and saved two MCP calls in each controlled native complete case.
The backend still performed three reads. The retained partial-answer error means
this evidence supports neither a correctness gain nor expanded promotion.
Individual dynamic tools, prompts and resources, automatic synthesis and write
activation are deferred. #799 keeps held native-session refresh, broader quality,
token and latency benefit acceptance open.
