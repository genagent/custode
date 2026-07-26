defmodule Custode.Attention do
  @moduledoc """
  The attention resolver (#296): a pure function from one agent's facts to the
  single `Custode.Signal` that describes it, plus a ranking over many.

  ## Why this is a module and not a sort key

  The fleet page currently ranks itself, inline, in `CustodeWeb.FleetLive`:

      {if(needs_attention?(tile.status), do: 0, else: 1),
       if(tile.state == :ended, do: 1, else: 0), activity_key(tile.last_activity), id}

  Attention is binary there, so everything that needs a human is then ordered
  by recency. On the live fleet that inverts the thing the operator wants: the
  OLDEST unanswered question sorts LAST among the agents needing attention,
  under four approvals raised in the last few minutes. Staleness is exactly
  what should rise, and recency-sorting is what buries it.

  Moving the decision here buys three things. It is testable, because it does
  no IO and reads no clock it was not handed. It is single, so the fleet page,
  the inbox, the digest and the CLI cannot drift into four slightly different
  ideas of what needs a human. And it is inspectable, because the result is a
  value the operator's judgment can be compared against rather than a sort
  key buried in a template.

  Everything here is pure. The impure half -- reading the registry, the gate
  rows and the ledger -- is `Custode.Attention.Fleet`.

  ## Precedence

  One agent resolves to ONE signal: the first kind whose condition holds.

  | # | kind | condition |
  | - | ---- | --------- |
  | 1 | `:needs_answer` | the agent asked the operator a question |
  | 2 | `:approval` | a gate is open that only the operator can pass |
  | 3 | `:red_check` | failing checks on the agent's own open PRs |
  | 4 | `:rail_hit` | the daily rail is reached |
  | 5 | `:stalled` | scheduled, running, producing no outcome (NOT IMPLEMENTED) |
  | 6 | `:working` | a turn is executing right now |
  | 7 | `:paused` | deliberately stopped |
  | 8 | `:scheduled` | healthy, next beat known |
  | 9 | `:quiet` | healthy, nothing found, nothing queued |

  A question outranks an approval because a question is blocked on a human by
  definition, whereas a gate is a structured hold the agent chose to raise and
  can describe. Both outrank a red check, which may still be the agent's to
  fix.

  Precedence is which kind WINS for one agent. Which group it lands in is a
  separate question, and `:red_check` is the case that separates them: it
  outranks a rail hit for a single agent, but it is not something the operator
  owes anyone. See `Custode.Signal` for the `:needs_you` / `:watching` split
  and why a red check sits in the second.

  ### Two deliberate departures from the design note

  `:paused` is checked BEFORE `:scheduled`, not last. A paused routine still
  has a cron, so testing `:scheduled` first would report an agent the operator
  stopped as healthy and counting down to a beat it will never run. The
  precedence claim that matters is the ordering WITHIN the needs-you kinds;
  the rest states are mutually exclusive and their order is a correctness
  question, not a ranking one.

  `:stalled` is defined and NOT implemented. A false stall is worse than no
  stall detection: it teaches the operator to distrust the needs-you group,
  which is the entire value of ranking. It needs a threshold tuned against
  real sweep history first, and it stays off until then.

  ## Offline is a rest state, not a fault

  Custode routines are cold-started by their own cron (`if_offline: "start"`),
  so a healthy scheduled agent reads `:offline` between beats for most of its
  life -- which is why the fleet page shows so many. An offline agent with a
  cron is `:scheduled`; an offline agent without one is `:quiet`. Neither is a
  problem, and drawing them as one is most of why the current page is hard to
  scan.
  """

  alias Custode.Signal

  # Ranked kinds, most urgent first. The index into this list IS the
  # precedence, so the table in the moduledoc and the ordering cannot drift.
  @precedence [
    :needs_answer,
    :approval,
    :red_check,
    :rail_hit,
    :stalled,
    :working,
    :paused,
    :scheduled,
    :quiet
  ]

  @groups %{
    needs_answer: :needs_you,
    approval: :needs_you,
    red_check: :watching,
    rail_hit: :needs_you,
    stalled: :needs_you,
    working: :working,
    scheduled: :scheduled,
    quiet: :quiet,
    paused: :quiet
  }

  @group_order [:needs_you, :watching, :working, :scheduled, :quiet]
  @urgency_order [:high, :normal, :low]

  # A rail is "hit" at 100%; the fleet page's own 80% banner (#211) stays a
  # separate, softer warning and is not an attention signal.
  @rail_hit_ratio 1.0

  @doc "The kinds, most urgent first."
  @spec kinds() :: [Signal.kind()]
  def kinds, do: @precedence

  @doc "The groups, in the order a page should stack them."
  @spec groups() :: [Signal.group()]
  def groups, do: @group_order

  @doc """
  The group a kind collapses into.

      iex> Custode.Attention.group_of(:needs_answer)
      :needs_you

      iex> Custode.Attention.group_of(:paused)
      :quiet
  """
  @spec group_of(Signal.kind()) :: Signal.group()
  def group_of(kind), do: Map.fetch!(@groups, kind)

  @doc """
  Resolve one agent's view to its single signal.

  `view` is a plain map of facts, built by `Custode.Attention.Fleet` in
  production and written by hand in tests:

    * `:id` -- the agent id. Required.
    * `:state` -- the lifecycle state atom (`:idle`, `:running`, `:paused`,
      `:offline`, `:awaiting_permission`, `:waiting_for_user`, `:ended`).
    * `:gate` -- the open gate row as `%{kind:, detail:, action_id:,
      opened_at:}`, or `nil`. Supplies the durable `raised_at` that the live
      status cannot: the gen_statem knows it is gated, not since when.
    * `:failing_checks` -- count of red checks on the agent's own open PRs.
    * `:spend_today` / `:budget` -- the daily ledger and the rail.
    * `:running_since` -- when the in-flight turn started, or `nil`.
    * `:cron` -- the schedule, or `nil` for a manual agent.
    * `:next_beat_at` -- when the next beat is due, if known.

  `context` carries anything the resolver must not read for itself:

    * `:now` -- the clock. Defaults to `DateTime.utc_now/0`, which is the one
      concession to convenience; pass it in tests.
    * `:stalled?` -- opt in to `:stalled` detection. Off, and unimplemented.
  """
  @spec resolve(map(), map()) :: Signal.t()
  def resolve(view, context \\ %{}) do
    context = Map.put_new_lazy(context, :now, &DateTime.utc_now/0)

    needs_answer(view, context) ||
      approval(view, context) ||
      red_check(view, context) ||
      rail_hit(view, context) ||
      stalled(view, context) ||
      working(view, context) ||
      paused(view, context) ||
      scheduled(view, context) ||
      quiet(view, context)
  end

  @doc """
  Order resolved signals for a human: group, then kind precedence, then
  urgency, then oldest-first, then the id as a stable tiebreak.

  Oldest-first inside a kind is the point. An approval that has been open for
  two hours is a worse state of the world than one raised a minute ago, and
  the current page orders them the other way round.
  """
  @spec rank([Signal.t()]) :: [Signal.t()]
  def rank(signals), do: Enum.sort_by(signals, &sort_key/1)

  @doc """
  Rank, then bucket by group, dropping empty groups.

  Returns a list of `{group, signals}` in `groups/0` order, ready for a page
  that stacks the needs-you rows above a collapsed tail.
  """
  @spec by_group([Signal.t()]) :: [{Signal.group(), [Signal.t()]}]
  def by_group(signals) do
    ranked = Enum.group_by(rank(signals), & &1.group)

    for group <- @group_order, signals = Map.get(ranked, group, []), signals != [] do
      {group, signals}
    end
  end

  defp sort_key(%Signal{} = signal) do
    {
      index_of(@group_order, signal.group),
      index_of(@precedence, signal.kind),
      index_of(@urgency_order, signal.urgency),
      raised_key(signal.raised_at),
      signal.subject
    }
  end

  # Unknown members sort last rather than raising: a ranking function is the
  # wrong place to crash a dashboard over an atom it has not met.
  defp index_of(list, value) do
    case Enum.find_index(list, &(&1 == value)) do
      nil -> length(list)
      index -> index
    end
  end

  # Oldest first, and signals with no timestamp (a red check, which the
  # overview cache cannot date) after the ones that have one.
  defp raised_key(%DateTime{} = at), do: {0, DateTime.to_unix(at, :microsecond)}
  defp raised_key(nil), do: {1, 0}

  defp needs_answer(view, _context) do
    if state(view) == :waiting_for_user or gate_kind(view) == "question" do
      signal(view, :needs_answer, :high,
        headline: "asked you a question",
        detail: detail(view),
        raised_at: gate_opened_at(view),
        resolving: [
          op("Answer", :answer, %{agent: view.id}),
          op("Open agent", :open_agent, %{agent: view.id})
        ]
      )
    end
  end

  defp approval(view, _context) do
    if state(view) == :awaiting_permission or gate_kind(view) == "approval" do
      action_id = get_in(view, [:gate, :action_id])

      signal(view, :approval, :high,
        headline: "wants your approval",
        detail: detail(view),
        raised_at: gate_opened_at(view),
        item: action_id,
        resolving: [
          op("Approve", :approve, %{agent: view.id, action: action_id}),
          op("Reject", :reject, %{agent: view.id, action: action_id}),
          op("Open agent", :open_agent, %{agent: view.id})
        ]
      )
    end
  end

  defp red_check(view, _context) do
    count = Map.get(view, :failing_checks, 0)

    if count > 0 do
      signal(view, :red_check, :normal,
        headline: "#{count} red #{pluralise(count, "check")} on its open PRs",
        # The overview cache cannot date a check result, so this signal has no
        # raised_at and ranks after any dated red check. Better than inventing
        # a timestamp that would then sort against real ones.
        raised_at: nil,
        resolving: [
          op("Inspect", :open_agent, %{agent: view.id}),
          op("Re-run checks", :rerun_checks, %{agent: view.id})
        ]
      )
    end
  end

  defp rail_hit(view, _context) do
    budget = Map.get(view, :budget)
    spend = Map.get(view, :spend_today, 0)

    if is_number(budget) and budget > 0 and spend / budget >= @rail_hit_ratio do
      signal(view, :rail_hit, :high,
        headline: "daily rail reached",
        detail: "spent #{format_usd(spend)} of #{format_usd(budget)}",
        resolving: [
          op("Raise the rail", :set_rail, %{agent: view.id}),
          op("Open agent", :open_agent, %{agent: view.id})
        ]
      )
    end
  end

  # Defined, deliberately unimplemented. See the moduledoc.
  defp stalled(_view, _context), do: nil

  defp working(view, context) do
    if state(view) == :running or Map.get(view, :running_since) do
      started = Map.get(view, :running_since)

      signal(view, :working, :low,
        headline: "a turn is running",
        detail: started && "started #{elapsed(started, context.now)} ago",
        raised_at: started,
        resolving: [op("Watch", :open_agent, %{agent: view.id})]
      )
    end
  end

  defp paused(view, _context) do
    if state(view) == :paused do
      signal(view, :paused, :low,
        headline: "paused",
        resolving: [op("Resume", :resume, %{agent: view.id})]
      )
    end
  end

  defp scheduled(view, _context) do
    if scheduled?(view) do
      signal(view, :scheduled, :low,
        headline: "next beat #{Map.get(view, :cron)}",
        resolving: [op("Beat now", :beat, %{agent: view.id})]
      )
    end
  end

  defp quiet(view, _context) do
    signal(view, :quiet, :low,
      headline: "nothing found in window",
      resolving: [op("Beat now", :beat, %{agent: view.id})]
    )
  end

  # A cron of nil or "manual" is an agent that only runs when told to. It is
  # at rest, not scheduled, and the fleet page should collapse it.
  defp scheduled?(view) do
    case Map.get(view, :cron) do
      cron when is_binary(cron) and cron != "" and cron != "manual" -> true
      _none -> false
    end
  end

  defp signal(view, kind, urgency, fields) do
    struct!(
      %Signal{
        subject: view.id,
        kind: kind,
        group: group_of(kind),
        urgency: urgency,
        headline: Keyword.fetch!(fields, :headline)
      },
      Keyword.delete(fields, :headline)
    )
  end

  defp op(label, op, args), do: %{label: label, op: op, args: args}

  defp state(view), do: Map.get(view, :state)

  defp gate_kind(view), do: get_in(view, [:gate, :kind])

  defp gate_opened_at(view), do: get_in(view, [:gate, :opened_at])

  # The live status payload carries the question or the action description;
  # the gate row carries the same text durably. Prefer whichever is present.
  defp detail(view), do: get_in(view, [:gate, :detail]) || Map.get(view, :detail)

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  defp format_usd(amount) when is_number(amount) do
    "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)
  end

  defp elapsed(%DateTime{} = from, %DateTime{} = now) do
    case max(DateTime.diff(now, from), 0) do
      seconds when seconds < 60 -> "#{seconds}s"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds -> "#{div(seconds, 3600)}h"
    end
  end
end
