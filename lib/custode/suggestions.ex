defmodule Custode.Suggestions do
  @moduledoc """
  Standing advisor suggestions (#284): the shared read + apply path for the
  fleet rail (which shows the top few) and the suggestions page (which shows
  them all). The advisors (#124/#125/#262) record `advisor_suggestion` feed
  entries; this context surfaces the ones still standing and applies an
  accepted one through the roster write-back (#192).

  A suggestion leaves the list once applied: the advisor's seen-set stops the
  re-suggest, and the `advisor_applied` entry masks the already-recorded
  suggestion row for the rest of the window.
  """

  alias Custode.{Config.WriteBack, Feed}

  @window_s 7 * 24 * 60 * 60

  @doc """
  Every standing suggestion in the window, deduped, newest first (uncapped).
  A suggestion masked by an APPLIED or a DISMISSED entry (same change
  identity) is dropped -- so a dismissed one stays gone for the window even if
  the advisor re-proposes it.
  """
  def standing do
    resolved = resolved_keys(["advisor_applied", "advisor_dismissed"])

    "advisor_suggestion"
    |> Feed.recent_by_event(limit: 50, since: @window_s)
    |> Enum.reject(&({&1["agent"], &1["field"], &1["proposed"]} in resolved))
    |> Enum.uniq_by(&{&1["advisor"], &1["agent"], &1["field"]})
  end

  defp resolved_keys(events) do
    for event <- events,
        entry <- Feed.recent_by_event(event, limit: 50, since: @window_s),
        into: MapSet.new(),
        do: {entry["agent"], entry["field"], entry["proposed"]}
  end

  @doc "The three fields the advisor trio proposes and the dashboard can apply."
  def applicable_field?(field), do: field in ["model", "cron", "daily_budget_usd"]

  @doc """
  Apply a suggestion through the roster write-back (#192): the operator
  clicking the dashboard is their own authority. Records an `advisor_applied`
  feed entry so the suggestion leaves the list. Returns `{:ok, message}` or
  `{:error, reason}`.
  """
  def apply(agent, field, proposed) do
    with {:ok, changes} <- changes(field, proposed),
         {:ok, _path} <- WriteBack.update_routine(agent, changes) do
      Feed.record(%{
        event: "advisor_applied",
        agent: agent,
        advisor: advisor_for(agent, field, proposed),
        field: field,
        proposed: proposed,
        summary: "operator applied suggestion: #{field} -> #{proposed}"
      })

      {:ok, "#{agent}: #{field} -> #{proposed} applied, live now"}
    end
  end

  # The three answers a dismissal actually carries (#303). They are not
  # severities: they say something different about the advisor each time, and
  # only the last is a judgment failure.
  #
  #   wrong_evidence -- the advisor read the fleet incorrectly
  #   not_now        -- correct, badly timed. A scheduling problem, not a
  #                     judgment one, and the most common real answer
  #   disagree       -- the operator rejects the reasoning itself
  #
  # A silent dismissal cannot tell them apart, which is why an advisor that
  # is right but early looks identical to one that is simply wrong.
  @dismiss_reasons [
    {"wrong_evidence", "wrong evidence"},
    {"not_now", "right, but not now"},
    {"disagree", "I disagree with this"}
  ]

  @doc "The offered dismissal reasons as `{key, label}`, in display order."
  def dismiss_reasons, do: @dismiss_reasons

  @doc "The human label for a dismissal reason key, or nil for an unknown one."
  def dismiss_reason_label(key) do
    Enum.find_value(@dismiss_reasons, fn {reason, label} -> reason == key && label end)
  end

  @doc """
  Dismiss a suggestion (#290): records an `advisor_dismissed` entry so it
  leaves the list and stays gone for the window, keyed by the change identity
  so a re-proposal of the same change stays masked too.

  `reason` is one of `dismiss_reasons/0`'s keys, or nil (#303). It costs the
  operator one click and is the only feedback an advisor gets that does not
  need an observation window to arrive, so the reason is recorded on the
  entry where an advisor's record can read it back.
  """
  def dismiss(agent, field, proposed, reason \\ nil) do
    label = dismiss_reason_label(reason)

    Feed.record(%{
      event: "advisor_dismissed",
      agent: agent,
      advisor: advisor_for(agent, field, proposed),
      field: field,
      proposed: proposed,
      reason: reason,
      summary:
        "operator dismissed suggestion: #{field} -> #{proposed}" <>
          if(label, do: " (#{label})", else: "")
    })

    {:ok,
     "#{agent}: #{field} -> #{proposed} dismissed" <> if(label, do: " -- #{label}", else: "")}
  end

  # Which advisor proposed this change (#304). An apply or a dismiss records
  # only the change, so without this the outcome record cannot attribute
  # anything to the advisor that earned it -- and an advisor's reputation is
  # exactly what its dismissals are evidence about.
  #
  # Read from the raw suggestion entries rather than standing/0: by the time
  # a second decision is made on the same change, the first has masked it.
  defp advisor_for(agent, field, proposed) do
    "advisor_suggestion"
    |> Feed.recent_by_event(limit: 50, since: @window_s)
    |> Enum.find_value(fn entry ->
      (entry["agent"] == agent and entry["field"] == field and
         entry["proposed"] == proposed) && entry["advisor"]
    end)
  end

  defp changes("model", value) when is_binary(value), do: {:ok, %{model: value}}
  defp changes("cron", value) when is_binary(value), do: {:ok, %{cron: value}}

  defp changes("daily_budget_usd", value) do
    case Float.parse(value) do
      {usd, ""} -> {:ok, %{daily_budget_usd: usd}}
      _other -> {:error, {:unparseable_budget, value}}
    end
  end

  defp changes(field, _value), do: {:error, {:unapplicable_field, field}}
end
