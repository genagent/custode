# Deterministic GenAgent host adapter proof

Bounded implementation of #880, a fixture slice of #777. This is a standalone
Mix project, not a replacement runtime wired into Custode.

The proof exercises SQLite/Ecto storage, Oban's Lite engine and executor,
GenAgent 0.7.0, the Claude backend, ClaudeWrapper, and the real Forcola runner.
Its only native workload is `test/fixtures/cli.py`: a synthetic CLI and one
synthetic tool process. The runner rejects any other executable and verifies
the captured fixture digest before launching. There are no model requests.

## What is implemented

`lib/journal.ex` contains the three proof schemas and transaction boundaries:

- `projects`: pause, control revision, generation and active turn slot.
- `project_turns`: queued/running/uncertain/completed state, request spec and
  zero or one canonical report. The fixture report is deliberately minimal.
- `project_turn_attempts`: unique turn binding, generation, immutable captured
  launch input/hash, one-use dispatch phase, early native session checkpoint,
  observed process inventory, terminal receipt, stop request and independent
  quiescence evidence.

Oban jobs refer to the durable turn ID. Repeated delivery finds that turn's
existing attempt instead of creating another invocation. Admission commits
before dispatch; pause prevents later admissions without revoking an admitted
permit. GenAgent's `pre_turn` consumes the permit transactionally. A captured
prompt from another generation, project or consumed attempt is rejected.
Ordinary callbacks return no followup; a deliberately hostile callback in A4
checks that the guard also applies to internally generated prompts.

Reconciliation is observational, not permit revocation. An original admitted
caller may still consume its unused permit once; a replacement delivery never
resubmits it. Recovering an unused permit into a new generation requires owner
fencing and is outside this proof. A2 specifically checks that redelivery
before launch does not invalidate the original caller's admission.

`lib/runtime.ex` keeps result ingestion separate from the Oban executor. Early
native checkpoints are written from the backend path, and a separately
supervised sink receives terminal observations. A report and slot release
commit together only after both a terminal receipt and bound quiescence
evidence exist. Late duplicate results cannot overwrite a report or release a
successor's slot. Losing the outcome leaves an uncertain turn even if native
exit is known. Resume changes pause only; it does not clear uncertainty.

`test/support/fixture.ex` is an independent socket/OS witness. It observes the
fixture's finite process inventory, records scratch-file effects, and verifies
that both known processes are absent or non-executing zombies. It does not
accept a stop acknowledgement or a terminal JSON frame as evidence of exit.
The CLI can put its tool into a new session to exercise escaped descendants.

## Deterministic matrix

| Case | Fault or ordering | Required observation |
| --- | --- | --- |
| A1 | Pause before admission; restart the Ecto repo | No launch; scheduled and direct work held; pause survives |
| A2 | Admission before pause, duplicate delivery before launch | Original permit survives reconciliation; exactly one invocation/report; successor held |
| A3 | Executor dies after admission, before permit consumption | Redelivery holds uncertainty and never resubmits the unused permit |
| A3b | Executor and lead die after consumption, before native launch | Same job redelivery does not launch; resume cannot clear slot |
| A4 | Duplicate jobs, stale generation, callback followup, explicit resume | One eligible invocation; no unadmitted followup or implicit resume |
| B1 | Executor dies after native start | CLI still produces effects; independent sink persists one report; same job reconciles |
| B2 | Receipt blocked before commit, then executor dies | Releasing the sink commits the receipt independently |
| B3 | Settlement commits, executor dies before Oban ack | Same job redelivers without invocation; late result cannot overwrite report or release successor |
| B4 | Sink dies before receipt, lead/outcome lost, repo restarted | Native exit alone leaves uncertain state and occupied slot |
| C1 | Terminal result while tool can still write | Terminal retained; no report/slot release until observed exit |
| C2 | Misleading stop acknowledgement while tool writes | Stop request retained; quiescence remains unknown |
| C3 | Interrupt exact request; CLI and tool ignore TERM | Runner escalation followed by observed exit; no invented outcome |
| C4 | Abrupt lead death with tool in another session | Parent exits; escaped tool still writes; slot stays occupied |
| C4b | Abrupt lead death with tool in the original group | Group members stop; unknown outcome still holds slot |
| Guard | Wrong executable or changed digest | Rejected before any native invocation |

Races use explicit message barriers, not sleeps. Bounded polling only observes
OS exit after a causal action; elapsed silence is never evidence of settlement.
Oban runs in manual test mode: `drain_queue` invokes its real Lite fetch,
executor and acknowledgement path in a disposable supervised task. Killing
that task kills the executing waiter. The same-job tests reset its durable job
to available only after observing DOWN, simulating redelivery. They do not
qualify an automatic Oban orphan-rescue service or a live queue producer.

## Run and inspect

From this directory, with Elixir 1.20/OTP 29, Python 3 and POSIX process support:

```sh
export MIX_ENV=test GEN_AGENT_HEX=1
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --seed 1
mix test --seed 12345
mix test --seed 777
mix dialyzer
```

Each case creates its own temporary SQLite database and scratch workspace.
The A/B/C scenarios write `tmp/evidence/<case>-<seed>.json`, containing ordered
native/barrier observations, journal snapshots at barriers, final records and
Oban delivery state. Each run also writes a manifest with resolved package
versions, toolchain, Python identity, native shim digest, source base/dirty
state and source file digests. The lockfile pins all resolved dependencies.
Local evidence is ignored by Git. Dedicated CI wiring is deferred: the current
GitHub credential cannot update workflow files. The existing repository CI
does not execute this standalone project; run the commands above explicitly.

## Qualification and remaining boundary

The deterministic host protocol is qualified only for this closed fixture
inventory and the tested dependency/platform combination. A conservative hold
passes the negative safety cases; it is not automatic-stop qualification.

The witness knows exactly which processes the fixture can create, uses a
per-run token and persists their observations. Numeric PIDs and `ps` are not a
portable production containment or process-birth identity mechanism. An
unobserved descendant, full BEAM/host restart, remote execution, multiple host
writers, scheduler catch-up, transport reconnect and automatic result recovery
remain outside this proof. No external side effect is reversed by local exit.

The current ClaudeWrapper Forcola streaming adapter hides native stream errors
and kills its stream task when enumeration halts. A GenAgent completion does
not supply a durable native settlement receipt. These fixtures therefore use
their independent witness, not a claimed production runner guarantee. C4
demonstrates why process-group cleanup alone cannot qualify escaped tools on
this path. Before runtime adoption, a durable invocation identity and a runner
settlement/recovery contract must replace that fixture witness. #777 stays open.

## Operating note

Only this standalone project changes. Its generated migration
belongs to its disposable repo; there are no Custode production migrations,
dependency changes, runtime hooks, prompts, schedules, UI or MCP changes. Do
not migrate or restart the fleet for this proof. Live provider smoke tests and
delegated model review were not run under this task's no-live-provider scope.
