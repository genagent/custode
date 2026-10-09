defmodule Custode.ProjectReportDigest do
  @moduledoc "Bounded owner reports and unresolved decisions, without dispatch or acceptance."

  import Ecto.Query, only: [from: 2]

  alias Custode.{ExecutionFacts, Feed, IntervalReports, Repo, Routine}
  alias Custode.Operator.Authority

  @max_projects 50
  @max_reports 3
  @decision_limit 3
  @stale_seconds 48 * 60 * 60

  def read(actor, opts \\ []) do
    with :ok <- authorize(actor),
         {:ok, options} <- options(opts) do
      routines = Routine.all() |> Enum.sort_by(& &1.id)
      selected = Enum.take(routines, options.project_limit)
      since = DateTime.add(options.now, -options.window_hours * 3600)

      {:ok,
       %{
         schema_version: "custode.project_report_digest.v1",
         observed_at: iso(options.now),
         window: %{since: iso(since), until: iso(options.now), hours: options.window_hours},
         coverage: %{
           configured_projects: length(routines),
           shown_projects: length(selected),
           has_more_projects: length(routines) > length(selected),
           project_limit: options.project_limit,
           report_limit: options.report_limit,
           decision_limit_per_kind: @decision_limit,
           scope:
             "Configured owners only; unconfigured owners and fleet infrastructure remain in Inbox."
         },
         projects: Enum.map(selected, &project(&1, since, options)),
         evidence:
           "Reports are agent-authored claims, not independent verification or acceptance.",
         consistency: "Independent current reads; this is not an atomic snapshot.",
         links: %{inbox: "/inbox", operations: "/metrics"}
       }}
    end
  end

  @doc "Read one configured owner's digest, including owners outside the fleet page limit."
  def read_project(actor, routine_id, opts \\ []) do
    with :ok <- authorize(actor),
         {:ok, options} <- options(opts),
         {:ok, routine} <- configured_routine(routine_id) do
      since = DateTime.add(options.now, -options.window_hours * 3600)
      {:ok, project(routine, since, options)}
    end
  end

  defp configured_routine(id) when is_binary(id) and id != "" do
    case Routine.get(id) do
      nil -> {:error, :unknown_routine}
      routine -> {:ok, routine}
    end
  end

  defp configured_routine(_id), do: {:error, :invalid_routine_id}

  defp authorize(%{kind: kind, id: id} = actor)
       when kind in [:operator, :routine] and is_binary(id) and id != "",
       do: Authority.fleet_control(actor)

  defp authorize(_actor),
    do: {:error, "identity: project digest requires the operator or caretaker"}

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(
           Keyword.keys(opts),
           &(&1 in [:window_hours, :project_limit, :report_limit, :now])
         ) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      values = %{
        window_hours: Keyword.get(opts, :window_hours, 24),
        project_limit: Keyword.get(opts, :project_limit, 25),
        report_limit: Keyword.get(opts, :report_limit, 1),
        now: Keyword.get(opts, :now, DateTime.utc_now())
      }

      if bounded?(values.window_hours, 168) and bounded?(values.project_limit, @max_projects) and
           bounded?(values.report_limit, @max_reports) and match?(%DateTime{}, values.now),
         do: {:ok, values},
         else: {:error, :invalid_bounds}
    else
      {:error, :invalid_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_options}
  defp bounded?(value, maximum), do: is_integer(value) and value >= 1 and value <= maximum

  defp project(routine, since, options) do
    query =
      from(f in Feed.Entry,
        where:
          f.agent == ^routine.id and f.event in ["turn", "turn_failed"] and f.at <= ^options.now,
        order_by: [desc: f.at, desc: f.id]
      )

    latest = query |> from(limit: 1) |> Repo.one()

    window_rows =
      Repo.all(from(f in query, where: f.at >= ^since, limit: ^(options.report_limit + 1)))

    # A recorded report is a claim. Retain its last stated concerns outside the
    # window too, but never label them unresolved facts or infer their resolution.
    latest_report =
      Repo.one(
        from(f in query,
          where: fragment("json_type(?, '$.report')", f.entry) == "object",
          limit: 1
        )
      )

    facts = ExecutionFacts.read(routine.id, routine: routine)

    %{
      owner: routine.id,
      repo: routine.repo,
      configured_role: to_string(routine.role),
      configured_provider: to_string(routine.provider),
      links: %{
        conversation: "/agents/#{URI.encode(routine.id, &URI.char_unreserved?/1)}/conversation",
        control_room: "/console/#{URI.encode(routine.id, &URI.char_unreserved?/1)}"
      },
      freshness: freshness(latest, since, options.now),
      reports: Enum.map(Enum.take(window_rows, options.report_limit), &report/1),
      has_more_reports: length(window_rows) > options.report_limit,
      reported_concerns: reported_concerns(latest_report),
      decisions: decisions(routine.id),
      execution: %{
        applied: execution(facts.applied),
        active: execution(facts.active),
        observation_error: error_text(facts.live_error)
      }
    }
  end

  defp execution(nil), do: nil

  defp execution(facts),
    do: Map.take(facts, [:provider, :state, :job_id, :attempt, :generation, :turn_id])

  defp error_text(nil), do: nil
  defp error_text(error), do: error |> inspect() |> String.slice(0, 200)

  defp freshness(nil, _since, _now),
    do: %{state: "missing", latest_recorded_at: nil, within_window: false, stale_after_hours: 48}

  defp freshness(latest, since, now) do
    %{
      state: if(DateTime.diff(now, latest.at) > @stale_seconds, do: "stale", else: "recent"),
      latest_recorded_at: iso(latest.at),
      within_window: DateTime.compare(latest.at, since) != :lt,
      stale_after_hours: 48
    }
  end

  defp report(row) do
    entry = Jason.decode!(row.entry)

    {contents, error} =
      case IntervalReports.validate(entry["report"]) do
        {:ok, contents} -> {contents, entry["report_error"]}
        {:error, error} -> {nil, error}
      end

    %{
      id: row.id,
      event: row.event,
      recorded_at: iso(row.at),
      summary: short(entry["summary"]),
      report: contents,
      report_error: short(error),
      evidence: "agent_authored",
      provenance:
        Map.take(
          entry,
          ~w(provider job_id job_attempt origin correlation_id config_revision generation turn_id)
        )
    }
  end

  defp reported_concerns(nil), do: nil

  defp reported_concerns(row) do
    case report(row) do
      %{report: %{"blockers" => blockers, "decisions" => decisions}} = report
      when blockers != [] or decisions != [] ->
        Map.take(report, [:id, :recorded_at, :evidence])
        |> Map.merge(%{blockers: blockers, decisions: decisions, resolution: "not established"})

      _none ->
        nil
    end
  end

  defp decisions(id) do
    asks =
      Repo.all(
        from(a in Custode.Asks.Ask,
          where: a.agent_id == ^id and a.status == "open",
          order_by: [asc: a.inserted_at, asc: a.id],
          limit: ^(@decision_limit + 1)
        )
      )

    gates =
      Repo.all(
        from(g in Custode.Gates.Gate,
          where: g.agent_id == ^id and g.status == "open",
          order_by: [asc: g.inserted_at, asc: g.id],
          limit: ^(@decision_limit + 1)
        )
      )

    %{
      asks: Enum.map(Enum.take(asks, @decision_limit), &decision(&1, "ask")),
      gates: Enum.map(Enum.take(gates, @decision_limit), &decision(&1, "gate")),
      has_more_asks: length(asks) > @decision_limit,
      has_more_gates: length(gates) > @decision_limit,
      evidence: "current open rows, independent of the report window"
    }
  end

  defp decision(row, kind) do
    %{
      id: row.id,
      kind: kind,
      status: row.status,
      opened_at: iso(row.inserted_at),
      text: short(Map.get(row, :question) || Map.get(row, :detail)),
      blocking: kind == "gate"
    }
  end

  defp short(nil), do: nil
  defp short(text) when is_binary(text), do: String.slice(text, 0, 1000)
  defp short(_other), do: nil
  defp iso(nil), do: nil
  defp iso(date), do: DateTime.to_iso8601(date)
end
