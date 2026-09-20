defmodule Custode.Advisors.Record do
  @moduledoc """
  Each advisor's record: what it proposed, what became of it, what it cost
  (#304).

  ## What this answers

  One question, and it is the one that decides whether an advisor is worth
  reading: **when this advisor speaks, is it usually right?**

  `Custode.Suggestions.Outcome` (#303) already knows what happened to each
  decision. Grouping that by advisor turns a list of individual outcomes into
  a reputation, which is the thing an operator actually wants when a card
  appears on the dashboard at 7am.

  ## Dismissals count, and they do not all count the same

  A dismissal with a reason (#303) is the cheapest signal an advisor gets.
  The breakdown matters more than the total:

    * `not_now` is a TIMING problem, not a judgment one. An advisor whose
      dismissals are mostly this is right and early, which is a different
      failure from being wrong, and a bare dismissal count would flatten them
      together.
    * `wrong_evidence` says it read the fleet incorrectly.
    * `disagree` is the only one that rejects the reasoning itself.

  ## Cost, honestly

  design/004 gives advisors two grades. A `:deterministic` advisor reads the
  fleet and spends nothing, so "does reflection pay for itself" has a trivial
  answer: yes, it was free. Only a `:judgment` advisor makes a bounded LLM
  call, and only that one has a cost worth putting beside its record.

  Today that is `advisor-retro` alone. Reporting `$0.00` for the other three
  is not a placeholder; it is the fact, and it is why the question is only
  interesting for one of them.

  ## What this deliberately does NOT do

  design/005 pairs the track record with an autonomy ladder: propose, then
  apply-and-tell, then apply-silently, earned by the record. **Custode has no
  rungs.** Every advisor proposes and only the operator applies. Building a
  ladder UI now would be chrome over a capability that does not exist, and
  the record has to come first anyway, because the rung is a function of it.

  So this answers "is it worth reading" and leaves "how much rope does it
  get" for when there is rope to give.
  """

  alias Custode.Routine
  alias Custode.SpendLedger
  alias Custode.Suggestions
  alias Custode.Suggestions.Outcome

  @window_s 30 * 24 * 60 * 60

  defmodule Entry do
    @moduledoc "One advisor's standing in the window."

    @type t :: %__MODULE__{
            advisor: String.t(),
            grade: :deterministic | :judgment | :unknown,
            standing: non_neg_integer(),
            applied: non_neg_integer(),
            settled: non_neg_integer(),
            observing: non_neg_integer(),
            reverted: non_neg_integer(),
            superseded: non_neg_integer(),
            dismissed: non_neg_integer(),
            dismissed_by_reason: %{String.t() => non_neg_integer()},
            cost_usd: float()
          }

    defstruct advisor: nil,
              grade: :unknown,
              standing: 0,
              applied: 0,
              settled: 0,
              observing: 0,
              reverted: 0,
              superseded: 0,
              dismissed: 0,
              dismissed_by_reason: %{},
              cost_usd: 0.0
  end

  @doc """
  Every advisor that has said something in the window, busiest first.

  Options: `:since` (seconds, default 30 days), `:now` (the clock, for tests).
  """
  @spec all(keyword()) :: [Entry.t()]
  def all(opts \\ []) do
    since = Keyword.get(opts, :since, @window_s)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    history = Outcome.history(Keyword.put(opts, :since, since))
    standing = Suggestions.standing()

    advisors =
      (Enum.map(history, & &1.advisor) ++ Enum.map(standing, & &1["advisor"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    advisors
    |> Enum.map(&entry(&1, history, standing, since, now))
    |> Enum.sort_by(&{-total(&1), &1.advisor})
  end

  @doc "The advisor id to module map, for grades."
  @spec grades() :: %{String.t() => :deterministic | :judgment}
  def grades do
    for {name, _cron} <- Routine.advisors(), into: %{} do
      module = advisor_module(name)
      {advisor_id(module), grade(module)}
    end
  end

  defp entry(advisor, history, standing, since, now) do
    mine = Enum.filter(history, &(&1.advisor == advisor))
    dismissals = Enum.filter(mine, &(&1.decision == :dismissed))

    %Entry{
      advisor: advisor,
      grade: Map.get(grades(), advisor, :unknown),
      standing: Enum.count(standing, &(&1["advisor"] == advisor)),
      applied: Enum.count(mine, &(&1.decision == :applied)),
      settled: count(mine, :settled),
      observing: count(mine, :observing),
      reverted: count(mine, :reverted),
      superseded: count(mine, :superseded),
      dismissed: length(dismissals),
      dismissed_by_reason: by_reason(dismissals),
      cost_usd: cost(advisor, since, now)
    }
  end

  defp count(records, status), do: Enum.count(records, &(&1.status == status))

  # nil reasons group under "unsaid" rather than being dropped: a dismissal
  # with no reason is itself worth seeing, since it is the one shape that
  # teaches the advisor nothing.
  defp by_reason(dismissals) do
    Enum.frequencies_by(dismissals, &(&1.reason || "unsaid"))
  end

  # A deterministic advisor attributes no spend, so this is 0.0 and that is
  # the answer rather than a missing value. The window is measured from the
  # same `now` as the history beside it: measured from the wall clock, a
  # caller that injects `:now` gets history for one window and cost for
  # another (#454).
  defp cost(advisor, since, now) do
    SpendLedger.total(advisor, DateTime.add(now, -since, :second))
  end

  defp total(%Entry{} = entry) do
    entry.standing + entry.applied + entry.dismissed
  end

  # Routine owns the name -> module map; duplicating it here would go stale
  # the first time an advisor is added.
  defp advisor_module(name) do
    Routine.advisor_module(name)
  rescue
    ArgumentError -> nil
  end

  defp grade(nil), do: :unknown

  # `function_exported?/3` does not load a module, and answers false for one
  # that is not loaded yet. Until #435 the Cron plugin happened to load every
  # advisor at boot by holding it in the crontab; without that, the judgment
  # advisor read as :deterministic and its spend as "free".
  defp grade(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :grade, 0),
      do: module.grade(),
      else: :deterministic
  end

  defp advisor_id(nil), do: nil

  defp advisor_id(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> then(&("advisor-" <> &1))
  end

  @doc """
  A one-line rendering of an advisor's standing.

      advisor-budget: 4 applied (2 settled, 1 reverted), 3 dismissed, free
  """
  @spec describe(Entry.t()) :: String.t()
  def describe(%Entry{} = entry) do
    [
      "#{entry.applied} applied",
      "#{entry.settled} settled",
      "#{entry.reverted} reverted",
      "#{entry.dismissed} dismissed",
      cost_phrase(entry)
    ]
    |> Enum.join(", ")
  end

  defp cost_phrase(%Entry{grade: :judgment, cost_usd: usd}),
    do: "cost $#{:erlang.float_to_binary(usd, decimals: 2)}"

  defp cost_phrase(_entry), do: "free"
end
