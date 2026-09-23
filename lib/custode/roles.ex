defmodule Custode.Roles do
  @moduledoc """
  The fleet's roles, first-class. A role is the sharpest thing custode has:
  it is simultaneously a run's INTENT (a tight, single-job prompt), a tile's
  MEANING (one phone number, one job), and a gate/spend attribution boundary.
  This module is the single source of truth for what roles exist and where
  each sits in the fleet, so the prompt stack, the MCP allowlist, and the
  dashboard all read one definition instead of three scattered ones.

  ## The hierarchy

  The operated fleet is a tree, and the tree IS the permission model -- a
  role's tier decides its tools:

      operator     the human. The apex and the SOLE approver of gates.
                   Not a routine role; the top of the tree.
        |
      custode      the singleton fleet agent (role :caretaker). Watches the
                   whole fleet, holds roster authority, escalates to the
                   operator -- but never approves a sibling's gate. Exactly
                   one wears it. The only tier granted the operator tools.
        |
      specialist   the workforce: one role per subject (backlog_worker,
                   steward, reviewer, ...). Worker tools, subject scope,
                   one gated item per sweep.
        |
      sub_agent    delegated, ephemeral hands a routine spawns for a bounded
                   task. Not a roster role; the bottom of the tree.

  `grants/1` derives from `tier/1`: the `:custode` tier gets the operator
  tools, every specialist gets the worker set. This preserves the exact
  allowlist the fleet ran before the registry existed (only the caretaker
  was ever elevated).

  ## Reading a role

  Each role carries a one-line `summary` (its intent, surfaced on the agent
  page), the `tier` (its place in the tree), what it `watches` and `writes`
  (the shape of a run), and a `cadence` character (`:active` vs `:quiet`) the
  fleet page uses to make a loud worker and a mostly-green steward look
  different at a glance.
  """

  # Authority tiers, apex first. `:operator` and `:sub_agent` are the tree's
  # bookends -- real positions in the hierarchy, but not roster roles.
  @tiers [:operator, :custode, :specialist, :sub_agent]

  @roles %{
    caretaker: %{
      summary:
        "The custode agent: the singleton fleet meta-agent -- watches gates, siblings, and sensors, and escalates to the operator.",
      tier: :custode,
      singleton: true,
      watches: :fleet,
      writes: [:beats, :notes],
      cadence: :active
    },
    repo_caretaker: %{
      summary: "Custode tending its own repository, one gated change at a time.",
      tier: :specialist,
      watches: :self_repo,
      writes: [:prs],
      cadence: :active
    },
    backlog_worker: %{
      summary: "Drains a repository's issue board, one gated slice per sweep.",
      tier: :specialist,
      watches: :board,
      writes: [:prs],
      cadence: :active
    },
    specialist: %{
      summary:
        "Handles difficult persistent work with a high-capacity model for the entire sweep.",
      tier: :specialist,
      watches: :assignment,
      writes: [:notebook, :issues, :prs],
      cadence: :active
    },
    steward: %{
      summary:
        "A repository's groundskeeper: runs the health battery, files upkeep findings, and fixes the occasional doorknob.",
      tier: :specialist,
      watches: :condition,
      writes: [:issues, :prs],
      cadence: :quiet
    },
    reviewer: %{
      summary:
        "Reviews the fleet's ready PRs, one gated verdict per sweep; a needs-human verdict blocks the merge.",
      tier: :specialist,
      watches: :ready_prs,
      writes: [:reviews],
      cadence: :active
    },
    consistency_auditor: %{
      summary:
        "Compares like-repos for drift across the fleet and proposes one alignment per sweep.",
      tier: :specialist,
      watches: :cross_repo_drift,
      writes: [:issues, :prs],
      cadence: :quiet
    },
    star_tracker: %{
      summary: "Tracks a repository's stars over time from its sensor.",
      tier: :specialist,
      watches: :stars,
      writes: [:notebook],
      cadence: :quiet
    },
    contributor_watch: %{
      summary: "Watches for new contributors surfaced by its sensor.",
      tier: :specialist,
      watches: :events,
      writes: [:notebook],
      cadence: :quiet
    },
    quake_watch: %{
      summary: "Reports significant earthquakes from its sensor.",
      tier: :specialist,
      watches: :events,
      writes: [:notebook],
      cadence: :quiet
    },
    tutor: %{
      summary: "Teaches one human a language, one spaced-repetition card per sweep.",
      tier: :specialist,
      watches: :schedule,
      writes: [:notebook],
      cadence: :quiet
    },
    assistant: %{
      summary:
        "The least-privileged default: does exactly what its sweep prompt says and nothing more.",
      tier: :specialist,
      watches: :prompt,
      writes: [:notebook],
      cadence: :quiet
    }
  }

  @doc "The authority tiers, apex first (`:operator` and `:sub_agent` bookend the routine roles)."
  def tiers, do: @tiers

  @doc "All registered roles as `%{role => metadata}`."
  def all, do: @roles

  @doc "Whether `role` is a known roster role."
  def known?(role), do: Map.has_key?(@roles, role)

  @doc "The metadata map for `role`, or the assistant's (the least-privileged default) for an unknown role."
  def get(role), do: Map.get(@roles, role, @roles.assistant)

  @doc "The one-line intent of `role`, for the agent page and tile."
  def summary(role), do: get(role).summary

  @doc "The tier of `role` (its place in the hierarchy). Unknown roles read as `:specialist` (least privilege)."
  def tier(role), do: get(role).tier

  @doc "What `role` watches (the input that drives a run)."
  def watches(role), do: get(role).watches

  @doc "What `role` writes (the shape of its output)."
  def writes(role), do: get(role).writes

  @doc "The tile character of `role`: `:active` (loud) or `:quiet`."
  def cadence(role), do: get(role).cadence

  @doc "Whether `role` is a singleton (exactly one wearer across the fleet)."
  def singleton?(role), do: Map.get(get(role), :singleton, false)

  @doc """
  The tool bundle `role` is granted, derived from its tier: the `:custode`
  tier (the fleet agent) gets `:operator`, every specialist gets `:worker`.
  The permission model is the hierarchy.
  """
  def grants(role) do
    case tier(role) do
      :custode -> :operator
      _specialist -> :worker
    end
  end
end
