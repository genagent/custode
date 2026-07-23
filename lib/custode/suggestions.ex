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

  @doc "Every standing suggestion in the window, deduped, newest first (uncapped)."
  def standing do
    applied =
      "advisor_applied"
      |> Feed.recent_by_event(limit: 50, since: @window_s)
      |> MapSet.new(&{&1["agent"], &1["field"], &1["proposed"]})

    "advisor_suggestion"
    |> Feed.recent_by_event(limit: 50, since: @window_s)
    |> Enum.reject(&({&1["agent"], &1["field"], &1["proposed"]} in applied))
    |> Enum.uniq_by(&{&1["advisor"], &1["agent"], &1["field"]})
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
        field: field,
        proposed: proposed,
        summary: "operator applied suggestion: #{field} -> #{proposed}"
      })

      {:ok, "#{agent}: #{field} -> #{proposed} applied, live now"}
    end
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
