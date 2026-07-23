defmodule Custode.Advisors.Retro do
  @moduledoc """
  The first judgment-grade advisor (#262 / design 004 D3): a weekly look-back
  that reads the 7-day Digest (#259) and suggests what no single-metric rule
  sees -- "these two routines duplicate each other's coverage", "this repo's
  failures cluster after that dependency bump", "the reviewer's queue suggests
  raising cadence on weekdays only".

  It is NOT an agent: no gen_statem, no session, no tools. `observe/0` builds
  the digest deterministically (zero tokens); `suggest/1` makes ONE bounded
  LLM call over it (small model, hard cost cap, json-schema output) and
  returns typed suggestion maps that land through the exact same
  seen-set/cooldown and feed -> card -> accept path the deterministic trio
  uses. Suggest-only, cooldown-keyed, a one-shot on the sensor lane -- a
  sensor that thinks for one bounded moment.

  The digest is the ONLY input: no raw-telemetry prompting (design 004's hard
  line). If the digest is insufficient, extend `Custode.Digest`
  deterministically -- never widen this prompt.
  """

  use Custode.Advisor

  @advisor_id "advisor-retro"
  @window_days 7

  @impl Custode.Advisor
  def grade, do: :judgment

  @impl Custode.Advisor
  def observe, do: [Custode.Digest.build(@window_days)]

  @impl Custode.Advisor
  def suggest([digest]) do
    prompt = Custode.Digest.to_markdown(digest) <> "\n\n" <> instructions()

    case Custode.Advisor.judgment_call(prompt, schema(),
           system: system_prompt(),
           agent_id: @advisor_id
         ) do
      %{"suggestions" => list} when is_list(list) ->
        list |> Enum.map(&to_suggestion/1) |> Enum.reject(&is_nil/1)

      _none ->
        []
    end
  end

  # material key: a suggestion returns only when the underlying evidence
  # changes, so a dismissed retro insight does not re-nag every week
  @impl Custode.Advisor
  def key(suggestion) do
    "retro:#{suggestion.routine_id}:#{suggestion.field}:#{suggestion.evidence}"
  end

  # LLM output is string-keyed; convert to the atom-keyed suggestion shape the
  # chassis records. Drop anything missing the load-bearing fields.
  defp to_suggestion(%{} = raw) do
    routine_id = raw["routine_id"]
    field = raw["field"]

    if is_binary(routine_id) and is_binary(field) do
      %{
        routine_id: routine_id,
        field: field,
        current: raw["current"] || "",
        proposed: raw["proposed"] || "",
        evidence: raw["evidence"] || "",
        confidence: raw["confidence"] || "low"
      }
    end
  end

  defp to_suggestion(_other), do: nil

  defp system_prompt do
    """
    You are the fleet's retrospective advisor. You read a one-week fleet
    digest and propose a SMALL number of high-value tuning suggestions that
    no single-metric rule could find -- cross-routine patterns, clustered
    failures, cadence/budget mismatches. Suggest only; you never act. Only
    propose what the digest evidences; cite that evidence. If nothing in the
    digest warrants a suggestion, return an empty list.
    """
  end

  defp instructions do
    """
    From the digest above, return up to 5 suggestions as JSON. Each names the
    routine_id it concerns, the field to change (e.g. "cron", "model",
    "daily_budget_usd"), the current and proposed values, the evidence from
    the digest, and a confidence (low/medium/high). Return an empty list if
    the digest shows nothing worth changing.
    """
  end

  defp schema do
    Jason.encode!(%{
      type: "object",
      additionalProperties: false,
      required: ["suggestions"],
      properties: %{
        suggestions: %{
          type: "array",
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["routine_id", "field", "proposed", "evidence", "confidence"],
            properties: %{
              routine_id: %{type: "string"},
              field: %{type: "string"},
              current: %{type: "string"},
              proposed: %{type: "string"},
              evidence: %{type: "string"},
              confidence: %{type: "string", enum: ["low", "medium", "high"]}
            }
          }
        }
      }
    })
  end
end
