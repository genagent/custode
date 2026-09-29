# Custode self-maintenance

Custode source work belongs to the routine that serves `genagent/custode`. Fleet operation belongs to the caretaker. Keep those identities separate so repository work follows its issue, worktree, pull request, and approval path while the caretaker remains available for the rest of the fleet.

## Discover the two owners

1. Read `fleet.caretaker` from `operator_bootstrap`. Use that ID for fleet coordination and roster proposals.
2. Call `list_routines` and select rows whose `repo` is exactly `genagent/custode`.
3. If exactly one row matches, use its returned ID as the repository owner.
4. If several rows match, show their IDs, tags, working directories, providers, and states. Ask the caretaker or human which owns the change. Do not guess from a familiar name.
5. If none match, provision an owner through the reviewed path below. Do not work around the missing route by silently changing the source checkout yourself.

## Provision a missing repository owner

When a caretaker exists, send it one durable request to provision a routine for `genagent/custode` using current fleet conventions. Require it to inspect repository access, preview the exact roster entry and owned-checkout effect, and raise a roster-class gate. Relay that gate to the human. Only an explicit approval authorizes the caretaker's continuation to provision the checkout and add the routine.

If there is no caretaker, an authenticated external operator may use the same reviewed path directly:

1. Discover the current preview, owned-checkout, and roster tools and their schemas.
2. Choose a proposed ID and current repository-work profile. The maintained issue-to-pull-request profile is `backlog_worker`; do not assume a `repo_caretaker` profile exists.
3. Preview the routine and dry-run the owned checkout. Show the human the literal roster section, repository, destination, provider, cadence, rails, and expected effect.
4. Wait for explicit approval. The operator credential alone is not approval.
5. Provision the owned checkout with one stable idempotency key, then add the exact approved routine. Preserve and report a checkout if the roster add fails; do not delete or repurpose it automatically.
6. Read `list_routines` again and verify one row now serves `genagent/custode` before assigning work.

Do not hardcode `custode-dev`, a home directory, or a checkout path. Use returned IDs and deterministic owned-checkout paths from the connected installation.

## Assign one source change

Send the repository owner a bounded prompt that includes the issue and desired outcome. Require it to follow the repository's current `AGENTS.md` and the issue as data. In particular, it must:

- read the current design plan and issue, then evaluate any open pull request that already closes the issue;
- claim unclaimed work with `status/in-progress` and a draft pull request whose body states the plan, files, gates, and exclusions;
- use a sibling worktree rather than the checkout a fleet runs from;
- keep one issue, branch, conventional commit type, and pull request together;
- run the repository's five required gates before every push; and
- keep commits and prose free of AI attribution and use the repository's ` -- ` house aside.

Use one stable idempotency key with `prompt_agent`, retain its `message_id`, and follow that exact receipt with `await_agent`. A timeout leaves durable work in progress. You may manage another project while it runs; later bootstrap again, verify the installation, recover the receipt with `list_operator_messages`, and continue from the same IDs.

The repository routine proposes and implements through Custode gates. The human decides its gates. Once a reviewed change merges, update the running installation through the drained sequence in [lifecycle.md](lifecycle.md).
