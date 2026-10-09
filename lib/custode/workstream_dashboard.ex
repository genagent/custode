defmodule Custode.WorkstreamDashboard do
  @moduledoc """
  A bounded, read-only overview of configured routines as workstreams.

  Agreement intent and checkpoints remain attributed bookkeeping, reports
  remain agent-authored claims, and execution remains independently observed.
  No conversation bodies are loaded and no model or operator action is invoked.
  A targeted read uses the same sources even outside the overview's limit.

  Overview execution reuses the digest's observed process and active-turn
  summary. Desired settings and retained turns are omitted there (`nil` and
  `[]`); they are not claims that configuration or history is absent. A targeted
  read includes the full execution facts for the selected routine.

  A targeted read may page agreements with `agreement_before: agreement_id`,
  the `before_id` of a previous page. The cursor selects only the agreement
  page; reports, open decisions and execution remain current. An unknown,
  deleted or foreign cursor is an error, never the newest page.
  """

  alias Custode.Attention.Fleet

  alias Custode.{
    ExecutionFacts,
    NextBeat,
    ProjectReportDigest,
    Routine,
    Scheduler,
    Signal,
    WorkAgreements
  }

  @digest_options [:window_hours, :project_limit, :report_limit, :now]
  @options @digest_options ++ [:agreement_limit, :agreement_before, :routine_id]

  @doc "Read the overview, or a single configured workstream with `routine_id: id`."
  def read(actor, opts \\ []) do
    with {:ok, options} <- options(opts),
         {:ok, digest} <- digest(actor, options) do
      read_dashboard(actor, digest, options)
    end
  end

  defp read_dashboard(actor, digest, options) do
    signals = Fleet.signals()
    signals_by_id = Map.new(signals, &{&1.subject, &1})
    routines = Map.new(Routine.all(), &{&1.id, &1})

    sources = %{
      signals: signals_by_id,
      next_beats: NextBeat.pending(),
      routines: routines,
      detailed?: not is_nil(options.routine_id),
      agreement_before: options.agreement_before
    }

    with {:ok, workstreams} <- workstreams(actor, digest.projects, sources, options) do
      ranks = signals |> Enum.with_index() |> Map.new(fn {signal, i} -> {signal.subject, i} end)

      {:ok,
       %{
         schema_version: "custode.workstream_dashboard.v1",
         observed_at: digest.observed_at,
         window: digest.window,
         workstreams: Enum.sort_by(workstreams, &{Map.get(ranks, &1.id, length(signals)), &1.id}),
         attention: Enum.filter(signals, &Signal.needs_you?/1),
         coverage:
           Map.merge(digest.coverage, %{
             agreement_limit: options.agreement_limit,
             agreement_before: options.agreement_before,
             agreement_page: page_position(options.agreement_before)
           }),
         links: %{
           manager: "/custode",
           inbox: "/inbox",
           operations: "/metrics",
           control_room: "/console"
         },
         evidence:
           "Reports are agent-authored claims. Agreement records are attributed bookkeeping; " <>
             "only a human resolution accepts its exact submission and revision.",
         consistency: "Independent current reads; this is not an atomic snapshot."
       }}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) do
      agreement_limit = Keyword.get(opts, :agreement_limit, 3)
      agreement_before = Keyword.get(opts, :agreement_before)
      routine_id = Keyword.get(opts, :routine_id)

      cond do
        not (is_integer(agreement_limit) and agreement_limit in 1..10) ->
          {:error, :invalid_bounds}

        # Agreement pages are per owner; the fleet home always shows the newest.
        not is_nil(agreement_before) and is_nil(routine_id) ->
          {:error, :invalid_options}

        true ->
          {:ok,
           %{
             agreement_limit: agreement_limit,
             agreement_before: agreement_before,
             routine_id: routine_id,
             digest:
               opts
               |> Keyword.take(@digest_options)
               |> Keyword.put_new(:window_hours, 168)
               |> Keyword.put_new(:project_limit, 50)
               |> Keyword.put_new(:report_limit, 1)
               |> Keyword.put_new(:now, DateTime.utc_now())
           }}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp digest(actor, %{routine_id: nil, digest: options}),
    do: ProjectReportDigest.read(actor, options)

  defp digest(actor, %{routine_id: id, digest: options}) do
    with {:ok, project} <- ProjectReportDigest.read_project(actor, id, options) do
      now = options[:now]
      hours = options[:window_hours]
      count = length(Routine.all())

      {:ok,
       %{
         observed_at: DateTime.to_iso8601(now),
         window: %{
           since: DateTime.to_iso8601(DateTime.add(now, -hours * 3600)),
           until: DateTime.to_iso8601(now),
           hours: hours
         },
         projects: [project],
         coverage: %{
           configured_projects: count,
           shown_projects: 1,
           has_more_projects: count > 1,
           project_limit: 1,
           report_limit: options[:report_limit],
           scope: "One configured owner; fleet attention remains visible in Inbox."
         }
       }}
    end
  end

  defp workstreams(actor, projects, sources, options) do
    list_options =
      if is_nil(options.agreement_before),
        do: [limit: options.agreement_limit],
        else: [limit: options.agreement_limit, before_id: options.agreement_before]

    Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, rows} ->
      case WorkAgreements.list(actor, project.owner, list_options) do
        {:ok, agreements} ->
          {:cont, {:ok, [workstream(project, agreements, sources) | rows]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp workstream(project, agreements, sources) do
    id = project.owner
    signal = Map.get(sources.signals, id)
    routine = Map.get(sources.routines, id)

    next_beat =
      routine && (Map.get(sources.next_beats, id) || Scheduler.next_beat_at(routine.cron))

    execution = execution(project, sources)
    detail = "/workstreams/#{URI.encode(id, &URI.char_unreserved?/1)}"

    %{
      id: id,
      repo: project.repo,
      role: project.configured_role,
      purpose: purpose(agreements),
      digest: project,
      agreements: agreements,
      agreement_page: agreement_page(agreements, detail, sources),
      execution: execution,
      signal: signal,
      next_beat_at: next_beat,
      state: execution_state(execution, signal, next_beat),
      links: Map.put(project.links, :detail, detail)
    }
  end

  # Pages are keyed by an agreement id, not an offset, so agreements recorded
  # after a page was opened do not shift it. Only a detail read links pages.
  defp agreement_page(agreements, detail, sources) do
    before = sources.agreement_before
    next = sources.detailed? && agreements["has_more"] && agreements["before_id"]

    %{
      position: page_position(before),
      before: before,
      shown: length(agreements["agreements"]),
      has_more: agreements["has_more"],
      older: if(next, do: detail <> "?" <> URI.encode_query(%{"agreements_before" => next})),
      newest: if(is_nil(before), do: nil, else: detail)
    }
  end

  defp page_position(nil), do: :newest
  defp page_position(_before), do: :older

  defp execution(project, %{detailed?: false}) do
    %{
      desired: nil,
      turns: [],
      applied: project.execution.applied,
      active: project.execution.active,
      live_error: project.execution.observation_error
    }
  end

  defp execution(project, sources) do
    project.owner
    |> ExecutionFacts.read(routine: Map.get(sources.routines, project.owner))
    |> Map.update!(:live_error, &error_text/1)
  end

  defp purpose(agreements) do
    entries =
      Enum.map(agreements["agreements"], fn agreement ->
        intent = agreement["current"]["intent_record"]

        %{
          agreement_id: agreement["agreement_id"],
          revision: agreement["current_revision"],
          text: agreement["current"]["intent"]["outcome"],
          recorded_at: intent["recorded_at"],
          recorded_by: intent["recorded_by"]
        }
      end)

    %{
      entries: entries,
      state: if(entries == [], do: "missing", else: "recorded"),
      source: "work_agreements",
      evidence: "attributed_bookkeeping",
      has_more: agreements["has_more"]
    }
  end

  @doc false
  def execution_state(execution, signal, next_beat) do
    attention_state(signal) || observed_state(execution, signal, next_beat)
  end

  defp attention_state(%Signal{kind: kind} = signal) when kind in [:needs_answer, :approval],
    do: state("Waiting", signal.headline <> "; observed execution is shown separately.", :warning)

  defp attention_state(%Signal{group: :needs_you} = signal),
    do: state("Blocked", signal.headline <> "; operator attention is needed.", :error)

  defp attention_state(_signal), do: nil

  defp observed_state(execution, signal, next_beat) do
    applied_state = applied_state(execution)

    cond do
      applied_state == "paused" ->
        state(
          "Paused",
          "Lifecycle paused; this does not confirm the provider process stopped.",
          :warning
        )

      execution.live_error ->
        state("Unknown", "The current provider observation is unavailable.", :neutral)

      applied_state in ["waiting_for_user", "awaiting_permission"] ->
        state("Waiting", "The observed provider is waiting for input or approval.", :warning)

      working?(execution, applied_state) ->
        state(
          "Working",
          "A current provider turn is observed; completion is not established.",
          :info
        )

      scheduled?(next_beat, signal) ->
        state("Scheduled", "A next beat is scheduled; report coverage is independent.", :neutral)

      applied_state == "idle" ->
        state("Quiet", "The observed provider is idle; no active turn is established.", :neutral)

      true ->
        state(
          "Unknown",
          "No current provider process observed; missing reports do not establish inactivity.",
          :neutral
        )
    end
  end

  defp applied_state(%{applied: nil}), do: nil
  defp applied_state(%{applied: applied}), do: applied.state

  defp working?(execution, applied_state),
    do: not is_nil(execution.active) or applied_state == "running"

  defp scheduled?(_next_beat, %Signal{kind: :scheduled}), do: true
  defp scheduled?(next_beat, _signal), do: not is_nil(next_beat)

  defp state(label, detail, tone), do: %{label: label, detail: detail, tone: tone}
  defp error_text(nil), do: nil
  defp error_text(error), do: inspect(error)
end
