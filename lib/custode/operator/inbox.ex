defmodule Custode.Operator.Inbox do
  @moduledoc """
  The operator's view of what the fleet raised to them (#301).

  ## Not to be confused with `Custode.Inbox`

  `Custode.Inbox` is the AGENT-facing inbox: markdown files an agent reads
  with its own Read tool, which is how a restart notice reaches a routine and
  how #299's answers get back to the agent that asked. It is a delivery
  mechanism for machines.

  This is the human's side, and it delivers nothing. It is a READ of state
  that already exists. Sharing the word would put two unrelated things under
  one name in a codebase whose whole vocabulary discipline is that they must
  not; the namespace is the disambiguation.

  ## It ranks nothing

  Everything agent-raised comes from `Custode.Attention`, filtered to
  `:needs_you` and already ordered -- questions above approvals, oldest first
  within a kind. A second ranking here would put the fleet page and the inbox
  back in the business of disagreeing about what matters, which is the exact
  problem #296 existed to end.

  Advisor suggestions are the one thing that is not an attention signal (they
  are proposals, not states), so they follow the signals rather than
  interleaving with them.

  ## What never appears

  Sweeps, sensor pings, journal entries, turns. They live on their agents.
  The page states this out loud at the bottom: an inbox is only trustworthy
  if what it left out is named rather than silently dropped.

  The `:watching` group (design/007) is also excluded. A red check the fleet
  will look at on its own next beat was not raised to a human. If it turns out
  the operator wants it here, that is evidence the group split was wrong.
  """

  alias Custode.Attention
  alias Custode.Feed
  alias Custode.Signal
  alias Custode.Suggestions

  @read_event "inbox_read"

  defmodule Item do
    @moduledoc """
    One row. `actions` are `%{label:, op:, args:}` maps, taken straight off
    the signal's `resolving` list where there is one, so a new signal kind
    arrives in the inbox with working buttons and no template change.
    """

    @type t :: %__MODULE__{
            kind: atom(),
            subject: String.t(),
            headline: String.t(),
            detail: String.t() | nil,
            at: DateTime.t() | nil,
            actions: [map()],
            source: term()
          }

    defstruct [:kind, :subject, :headline, :detail, :at, :source, actions: []]
  end

  @doc """
  Everything raised to the operator: ranked attention signals first, then
  standing advisor suggestions newest-first.
  """
  @spec items() :: [Item.t()]
  def items, do: signal_items() ++ suggestion_items()

  @doc "Items raised since `at`, or all of them when `at` is nil."
  @spec since(DateTime.t() | nil) :: [Item.t()]
  def since(at), do: unread(items(), at)

  @doc """
  The pure half of `since/1`: which of `items` count as unread at `at`.

  An item with NO timestamp counts as unread. A signal that cannot be dated
  (a red check, whose result the overview cache cannot date) is better
  surfaced once too often than silently aged out of the one list the operator
  is meant to trust.
  """
  @spec unread([Item.t()], DateTime.t() | nil) :: [Item.t()]
  def unread(items, nil), do: items

  def unread(items, %DateTime{} = at) do
    Enum.filter(items, fn
      %Item{at: nil} -> true
      %Item{at: raised} -> DateTime.compare(raised, at) == :gt
    end)
  end

  @doc "When the operator last opened the inbox, or nil if never."
  @spec last_read_at() :: DateTime.t() | nil
  def last_read_at do
    case Feed.recent_by_event(@read_event, limit: 1) do
      [%{"at" => at} | _rest] -> parse(at)
      _none -> nil
    end
  end

  @doc """
  Record that the operator looked.

  A feed entry rather than a table: `Custode.Presence.set/1` already records
  operator actions this way, there is one operator, and the read mark is one
  timestamp. `Custode.Presence.away_window/0` cannot serve here -- it answers
  "did they just come back from an absence", returning `:none` the rest of
  the time, because it exists to greet rather than to track.
  """
  @spec mark_read() :: :ok
  def mark_read do
    Feed.record(%{
      event: @read_event,
      agent: "operator",
      summary: "operator read the inbox"
    })

    :ok
  end

  defp signal_items do
    for signal <- Attention.Fleet.signals(), Signal.needs_you?(signal) do
      %Item{
        kind: signal.kind,
        subject: signal.subject,
        headline: signal.headline,
        detail: signal.detail,
        at: signal.raised_at,
        actions: signal.resolving,
        source: signal
      }
    end
  end

  defp suggestion_items do
    Suggestions.standing()
    |> Enum.map(fn suggestion ->
      %Item{
        kind: :suggestion,
        subject: suggestion["advisor"] || "advisor",
        headline:
          "#{suggestion["agent"]} #{suggestion["field"]} " <>
            "#{suggestion["current"]} -> #{suggestion["proposed"]}",
        detail: suggestion["evidence"] || suggestion["summary"],
        at: parse(suggestion["at"]),
        actions: suggestion_actions(suggestion),
        source: suggestion
      }
    end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # Only the three fields the roster write-back can actually apply get an
  # apply button; the rest are readable advice with a dismiss.
  defp suggestion_actions(suggestion) do
    args = %{
      agent: suggestion["agent"],
      field: suggestion["field"],
      proposed: suggestion["proposed"]
    }

    apply_action =
      if Suggestions.applicable_field?(suggestion["field"]) do
        [%{label: "Apply", op: :apply_suggestion, args: args}]
      else
        []
      end

    apply_action ++ [%{label: "Dismiss", op: :dismiss_suggestion, args: args}]
  end

  defp parse(%DateTime{} = at), do: at

  defp parse(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  defp parse(_other), do: nil
end
