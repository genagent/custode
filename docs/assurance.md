# Scoped assurance records

`Custode.Assurance` is an opt-in record service on the routine path. It uses the
existing operations SQLite store. It launches no work and confers no authority
on repository, document, gate or workflow operations.

Configure an assignment in application configuration. The default is empty:

```elixir
config :custode,
  assurance_assignments: [
    %{
      id: "bounded-owner-review",
      owner_id: "project-owner",
      judge_id: "operator",
      max_rounds: 3,
      criteria: ["An independent verifier reproduced the pinned check."],
      policy: %{
        predicates: [
          %{
            name: "independent_check",
            sources: ["owner_review"],
            classes: ["independently_reproduced"],
            independent: true
          }
        ]
      }
    }
  ]
```

This example deliberately remains missing with the existing OwnerReviews
source: an authored review is an opinion, not an independently reproduced check.
The bounded native recorder described below supplies a separate source for checks
in the second slice of [design/023](../design/023-assurance-contract.md). A narrower policy can require
an authored opinion using `classes: ["self_reported"]`; that records the opinion
without verifying its propositions.

Each assignment has one current configured owner and a designated human judge.
It has 1 to 16 criteria and predicates, 1 to 16 revision rounds, and at most 256
retained events per case. Predicate names are unique. Sources are `owner_review`,
`document`, `execution`, `repository_check`, `native_check` and `native_opinion`;
recognized claim classes are
`self_reported`, `host_observed`, `external_attested`, `independent_opinion` and
`independently_reproduced`. Listing a class never upgrades an existing source.
The designated judge is an additional mandatory predicate.

## Recording operations

The shared operations accept an authenticated operator identity. They are not
exposed as model tools. Requests use string keys. `open/2` freezes `case_id`,
`assignment_id`, `objective`, `input` and `artifact`; optional `producer_job_id`
references an existing captured owner execution. Optional `producer_native_run_id`
references a recorder-observed native producer for this exact case and artifact;
the two producer references cannot be combined. Repository artifacts require
`kind=repository`, the owner's exact served repository, and a 40-character
commit SHA in `revision`. Document artifacts require `kind=document`, `root_id`,
`path` and the exact current bytes digest in `revision`.

The stored attempt includes objective/input/artifact/criteria revisions, the
configured policy digest, owner execution revision and a logical generation.
`revise/3` takes the new objective/input/artifact, `request_id` and the expected
current `generation`. It retains the old attempt and advances the generation
within the original round bound. A criteria or policy edit becomes current only
through a new revision; until then the read evaluation reports `current_policy`
missing and invalidates dependent eligibility.

`capture/3` takes `request_id`, `generation`, `predicate` and a source reference:

| Source | Required reference | What the recorder can establish |
| --- | --- | --- |
| `owner_review` | `review_id`, `slot` | Exact retained child and review input. Custody is host-observed; conclusions are self-reported. Native verifier execution remains unavailable. |
| `document` | `request_id` of publication | Existing receipt and current working bytes at capture. Exact publication/current revision proves presence. A known current mismatch contradicts presence. |
| `execution` | `job_id` | The existing captured job matches the frozen producer. Job observation does not verify the artifact. |
| `native_check` | `native_run_id` | Recorder-issued reproduction requires another actor/provider/session, the exact pinned command including absolute cwd, and coherent emitted check rows bound to the artifact and fixed check bytes. Missing bindings remain unknown. |
| `native_opinion` | `native_run_id` | Authored cold-verifier opinion bound to the case and artifact. Other-provider identity establishes independent opinion, never deterministic reproduction. |
| `repository_check` | `name` | Existing repository read requested at the pinned SHA. Current repository projections omit issuer and check head, so attestation validity remains missing. |

Use `review_input/2` to obtain the exact frozen envelope for an OwnerReviews
request. Text that merely mentions the artifact cannot supply that binding.
Caller payloads, trust classes and provider labels are refused. Source snapshots
and recorder-issued custody/claim classes are retained as facts.

`judge/3` takes `request_id`, `generation`, `outcome` (`passed`, `failed` or
`unknown`) and `reason`. Only the frozen designated human identity can record
this judgment. `decide/3` takes `request_id` and `generation` and retains an
explainable decision with exact evidence ids. A failed required predicate wins
over a passed one; missing bindings or judge escalation cannot be averaged away.
Acceptance is scoped to the pinned artifact and recorded observations. It is
never a current filesystem or GitHub recheck for effect admission.

Events are first-writer facts. An identical retry returns the original event,
including after a later revision. A different payload using the same global
request id conflicts. A new request against an old generation is refused.
Nothing silently replaces an old receipt or changes its class.

## Bounded native proof recorder

`Custode.Assurance.Native.launch/3` is an internal operator operation, disabled
unless `assurance_native_enabled=true` and the selected `assurance_native_profiles`
entry matches a current configured actor, owner, provider/model/effort and physical
workspace. It accepts only `request_id`, `profile_id` and expected `generation`.
Native calls select explicit null stdin (EOF) in the fixed runner helper; the
runner default remains inherited input. The non-secret `USER` environment entry
permits native macOS account lookup without changing credentials.
It records its own shell-free native argv, runner/stdin version, session, terminal events,
requested and observed model/effort, fixed check digest, command output and exit.
The fixed check accepts one exact JSON frame, optionally preceded by the retained
known macOS Git temp-directory diagnostic. Ambiguous output or other diagnostics
remain unknown; a failed native command with nonzero exit can establish check failure.
Imported provider labels, model-authored success and caller trust classes cannot
issue a reproduction receipt. Raw native output is bounded to 512,000 bytes and
retained once in its recorder row; evidence snapshots contain bounded metadata
and observation digests.

The narrow profile supports Claude producers with Read/Write tools, hooks disabled,
empty MCP configuration and an explicit effort and configured budget stop. That
stop is not a hard total-billing ceiling. Cold Codex verifiers use read-only sandbox,
explicit model/low effort and ignored user configuration/rules. Native managed
settings and unreported model/effort remain unknown. Profiles have at most a
180-second timeout; each case admits at most four launches.

An atomic physical-workspace reservation survives completed, failed and interrupted
launches. Identical request replay returns the retained record; another request
cannot reuse that workspace. Neither a native terminal nor runner cleanup proves
all descendants settled. The recorder explicitly retains missing all-descendants
attestation and never automatically redelivers an interrupted launch.

The paid proof task requires `MIX_ENV=test`, `CUSTODE_NATIVE_ASSURANCE_PROOF=1`,
a private 0700 `TMPDIR` and a fresh direct-child `--root`. It starts an isolated
operations store with queues/scheduler disabled and retains a private checkpoint
after every call. Explicit `--reassess` reads an existing private proof store and
recaptures its retained observations with new receipt/decision ids; it launches no
native process and preserves old receipts and decisions. The initial run configures
four calls, one Claude producer and cold
Codex verifier for each fixed clean and host-seeded case, without automatic retries.
The trusted fixture check actually reruns addition and wrapper checks against the
frozen artifact. Seed bytes and artifact Git commits are attributed to the host.
The proof-harness judge is synthetic; it does not mean a human reviewed or approved
the result. SQLite store-process reopen is bounded persistence evidence, not a full
VM crash or all-descendants settlement proof. All results retain effect authority
`none`. The ordinary test suite uses explicitly synthetic executable fixtures and
never invokes paid providers.

## Read surfaces

`assurance_read` is a read-only MCP tool. `mix custode assurance-read CASE_ID
--json` calls the same tool. The current standing owner may read its own case;
authenticated humans may read retained cases. Helpers and other owners cannot.
Reads retain no records, start no providers and expose no source payload snapshot.

The compact projection shows current exact bindings, bounded attempt history,
satisfied/missing/contradictory predicates, eligibility exclusions, source limits,
evidence references and immutable prior decisions. It separates current-policy
evaluation from a historical decision. Every result has `effect_authority=none`.

## Operating note

The migrations add `assurance_records` and `assurance_native_runs` to the operations store. A running fleet
needs a pull, migrate and restart to pick up the internal service and read tool.
No prompt changes or changes to approved-turn authority are included.
