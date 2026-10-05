# Bounded native crash controller

The explicit crash controller supplements #795's completed clean/seeded fixture
proof and fresh-process reconstruction audit. It does not grant effect authority,
release a workspace reservation or add a retry operation. Ordinary tests never
launch providers.

## Retained synthetic exercise

The [public projection](../spikes/assurance/native-crash-synthetic-results.json)
pins source revision and file hashes. Two fake CLI sessions emitted initialization
and waited. These are synthetic provider events, not actual Claude/Codex calls.
The independent controller observed its own OS process identities and exact
stdout writer before injecting each interruption:

- Worker interruption kept the owning BEAM process alive; the recorder persisted
  an incomplete launch.
- Owning BEAM interruption left a running launch in SQLite. A fresh BEAM process
  reopened the original store.

Both fresh recovery phases returned the original identical request, refused a
new request in its reserved workspace, explicitly advanced the case generation,
refused stale native evidence and escalated missing success. Eight controls
passed per case. Original native rows remained unchanged; no imported late
receipt, judge approval or effect authority appeared.

Synthetic initialization cannot establish native process behavior, inference
completion, quality or spend. The subsequent actual native exercise below is
separate evidence; the synthetic report remains unchanged.

## Actual approved native exercise

Exactly two explicitly approved native launch requests passed the controller at
source `1a3f275f96d2a8b3b58209c711b6ac5ab18f181d`. Both emitted actual native
initialization before interruption. No retry or additional native request was
made, and neither fresh recovery phase called a model.

| Actual interruption | Original durable native state | Fresh recovery controls |
| --- | --- | --- |
| Claude owned worker killed; owning BEAM remained alive | `incomplete` | All eight pass |
| Codex owning BEAM killed | `running` | All eight pass |

The [anonymous report](../spikes/assurance/native-crash-results.json) contains
provider/failure/state, call count and Boolean controls. Detailed source snapshots,
raw captures, native and process identities, their hashes, frozen contexts,
original SQLite stores and recovery records remain private. Independent review
checked the snapshots against pinned Git source, capture/process/context bindings,
original rows versus fresh recovery reports, and consistency of this projection.
Each store retains exactly one native row. Both recovered rows preserve the
original request and missing success, refuse workspace redelivery and stale
results, and admit no imported late evidence or effect authority.

The controller observed its own recorded identities disappear. Positive
all-descendant settlement remains missing, reservations remain held and safe
retry is not admitted. Initialization and interruption prove these crash controls,
not completed inference, quality, actual human acceptance or machine reboot.
The source and lockfile are pinned to the tested snapshot; later dependency
updates are not silently attributed to this exercise.

Together with the retained actual clean/seeded cross-provider checks and earlier
fresh-process request-to-decision reconstruction, this completes the bounded
first proof for #795 and #710. The selected judge remains the synthetic host
harness under the named policy. Broader human acceptance and physical settlement
are explicit limits, not facts established by closing that proof.

## Guard and evidence boundaries

The test-only `mix custode.assurance.crash_proof` phase requires explicit
`CUSTODE_NATIVE_CRASH_PROOF=1`, private existing `TMPDIR`, a fresh direct-child
root for launch, and private original context/store files for recovery. It refuses
an already running application. The isolated application has no standing
routines, scheduler or Oban queues. Recovery checks the original native row's
request fingerprint and workspace before any replay.

`spikes/assurance/native_crash.py` controls separate worker/recovery OS processes.
It fixes two provider slots and one model launch request per slot, stops on a
failed case and performs no automatic retry. The initialization deadline is
60 seconds. A recovery phase has a separate 60-second deadline. Captures read
at most 512,000 bytes per native output channel. Signals require a controller
observation plus fresh PID, birth-time and executable-image matching. Startup
exec transitions update image only while the process remains in the controlled
tree with unchanged birth time. The exact private stdout file descriptor binds
the selected native writer to the observed initialization.

Before either interruption, the controller retains stdout/stderr and its
observed identities. It revalidates only those identities for five-second cleanup.
Observed-process disappearance is bounded host evidence, not positive
all-descendant settlement. Detached unobserved processes and PID observations
between polls remain limits. Reservations stay durable even after observed
cleanup. Only a missing all-descendant attestation is published.

Every phase verifies the pinned source revision and file hashes. Private evidence
contains source snapshots, original store, raw native output, launch/context and
recovery records. The controller's `report-public.json` remains private for actual
native runs because it contains native identity and capture hashes. Only the
anonymous allowlist is published: provider/failure/state, call count, Boolean
controls and public Git source revision. The earlier synthetic projection is
separate. No new native identities, capture hashes, session/account metadata,
raw output or physical paths are published.
Claude's configured USD 0.5 stop is not a billing ceiling; Codex cost stays
unknown. Initialization establishes a session, not a completed inference.

## Reproduction

For the nonpaid exercise, from an isolated worktree set a private fresh proof
root and run the controller with `--synthetic` and explicit opt-in. The controller
sets its own test environment, isolated database, TMPDIR and port 6184. Do not
run concurrent app commands on that port. Use the same source hashes when
comparing retained reports. Omit `--synthetic` only for explicitly authorized
native requests after reviewing the concrete controller and fixture.

Guard/parser/privacy tests run normally with
`mix test test/custode/assurance_native_crash_proof_task_test.exs`. The controller's
synthetic process exercise is separately opt-in, never a paid test default.
