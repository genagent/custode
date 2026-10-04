defmodule Custode.IntervalReports do
  @moduledoc """
  Bounded agent-authored interval reports, separate from execution facts.

  The feed owns persistence. Reports never grant authority, attest acceptance
  or launch another turn. Missing reports retain legacy summary behavior.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo}

  @sections ~w(done verified next blockers decisions)
  @max_entries 3
  @max_length 500

  @doc "Stable report section order and display labels."
  def sections, do: Enum.map(@sections, &{&1, String.capitalize(&1)})

  @doc "Provider-neutral optional report schema."
  def schema do
    %{
      type: "object",
      additionalProperties: false,
      properties:
        Map.new(@sections, fn section ->
          {section,
           %{
             type: "array",
             maxItems: @max_entries,
             items: %{type: "string", minLength: 1, maxLength: @max_length}
           }}
        end)
    }
  end

  @doc "Validate without discarding an otherwise useful turn outcome."
  def validate(nil), do: {:ok, nil}

  def validate(report) when is_map(report) do
    if Enum.all?(Map.keys(report), &(&1 in @sections)) do
      Enum.reduce_while(@sections, {:ok, %{}}, fn section, {:ok, validated} ->
        validate_section(section, Map.get(report, section, []), validated)
      end)
    else
      {:error, "report supports only done, verified, next, blockers and decisions"}
    end
  end

  def validate(_report), do: {:error, "report must be an object or null"}

  defp validate_section(section, entries, validated) do
    if valid_entries?(entries) do
      {:cont, {:ok, Map.put(validated, section, entries)}}
    else
      {:halt,
       {:error,
        "report.#{section} must contain at most #{@max_entries} nonempty strings of at most #{@max_length} characters"}}
    end
  end

  defp valid_entries?(entries) when is_list(entries) and length(entries) <= @max_entries do
    Enum.all?(entries, fn entry ->
      is_binary(entry) and String.valid?(entry) and String.trim(entry) != "" and
        String.length(entry) <= @max_length
    end)
  end

  defp valid_entries?(_entries), do: false

  @doc "Add available execution provenance and validated report contents."
  def decorate(entry, output, integration, meta) do
    entry = Map.put(entry, :provider, provider(integration))
    entry = Map.merge(entry, provenance(meta))

    case validate(output["report"]) do
      {:ok, nil} -> entry
      {:ok, report} -> Map.put(entry, :report, report)
      {:error, error} -> Map.put(entry, :report_error, error)
    end
  end

  @doc "An exact completion identity; legacy events without a job have none."
  def ingestion_key(integration, %{job: %{id: id, attempt: attempt}})
      when is_integer(id) and is_integer(attempt),
      do: "#{integration}:job:#{id}:attempt:#{attempt}:turn"

  def ingestion_key(_integration, _meta), do: nil

  @doc "Recent recorded turns, including honest legacy summary-only evidence."
  def recent(agent, limit \\ 5) do
    rows =
      Repo.all(
        from(f in Feed.Entry,
          where: f.agent == ^agent and f.event == "turn",
          order_by: [desc: f.id],
          limit: ^limit
        )
      )

    entries =
      rows
      |> Enum.reverse()
      |> Enum.map(fn row ->
        row.entry
        |> Jason.decode!()
        |> Map.take(
          ~w(agent at summary report report_error provider job_id job_attempt origin correlation_id config_revision generation turn_id)
        )
        |> Map.put("id", row.id)
      end)

    %{
      entries: entries,
      latest_at: List.last(entries) && List.last(entries)["at"],
      evidence: "agent_authored",
      scope: "recent retained turns; absence is not proof of inactivity"
    }
  end

  defp provenance(%{job: %{meta: meta} = job}) when is_map(meta) do
    %{
      job_id: Map.get(job, :id),
      job_attempt: Map.get(job, :attempt),
      origin: meta["origin"],
      correlation_id: meta["correlation_id"],
      config_revision: meta["config_revision"],
      generation: meta["agent_generation"],
      turn_id: meta["agent_turn_id"]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp provenance(_meta), do: %{}
  defp provider(:oban_claude), do: "claude"
  defp provider(:oban_codex), do: "codex"
end
