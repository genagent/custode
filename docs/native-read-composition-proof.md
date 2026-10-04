# Native read-composition proof, 2026-10-04

Status: bounded evidence for #799; dynamic catalog acceptance remains open.
The native CLI processes called an isolated real Custode/Snodo HTTP endpoint.
Repository operations returned a controlled fixture, not live GitHub data.
Discovery was narrowed to four existing compiled tools by a measurement proxy;
this is not the full production catalog or a dynamic catalog implementation.

## Observed

| Client | Scenario | MCP calls | Backend reads | Returned text bytes | Run/capture ms | Reported USD |
|---|---|---:|---:|---:|---:|---:|
| Claude 2.1.284 | Three original reads | 3 | 3 | 233 | 6172 | 0.0225438 |
| Claude 2.1.284 | Composition | 1 | 3 | 461 | 5930 | 0.0147096 |
| Claude 2.1.284 | Partial failure | 1 | 2 | 343 | 6958 | 0.0158988 |
| Claude 2.1.284 | Denied repository | 1 | 0 | 44 | 4821 | 0.0131170 |
| Codex 0.157.1 | Three original reads | 3 | 3 | 233 | 14599 | unknown |
| Codex 0.157.1 | Composition | 1 | 3 | 461 | 11458 | unknown |
| Codex 0.157.1 | Partial failure | 1 | 2 | 343 | 12415 | unknown |
| Codex 0.157.1 | Denied repository | 1 | 0 | 44 | 11601 | unknown |

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
Returned bytes are not proof of model consumption. Native usage fields are
retained without assuming their accounting is comparable across providers.

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
case measurements plus both failed attempts. It includes exact native session
IDs, CLI versions, requested/observed models, usage, caller/definition/source
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

## Remaining #799 acceptance

No actual-client proof exists here for the newer protocol, tool/prompt/resource
catalog changes, list-change notifications, long-lived mid-session refresh or
reconnect behavior after a changed catalog. Fresh processes rediscovering the
same four tools are not that proof. Keep individual dynamic entries disabled;
the fixed dispatcher does not require them. This experiment does not expand
activation, provider authority, automatic mining or effect admission.
