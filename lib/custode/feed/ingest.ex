defmodule Custode.Feed.Ingest do
  @moduledoc """
  The telemetry half of the feed (#92 item 5): armored handlers that turn
  provider events into `Custode.Feed.record/2` calls. Storage and
  queries live in `Custode.Feed`; notification dispatch in
  `Custode.Feed.Notify`.
  """

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception],
    [:oban_codex, :agent, :transition],
    [:oban_codex, :run, :stop],
    [:oban_codex, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-feed", @events, &__MODULE__.handle_event/4, nil)
  end

  # :telemetry DETACHES a handler that raises -- one transient Repo/file
  # error would silently kill this pipeline until restart (audit
  # 2026-07-21). Never raise out of a handler.
  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      require Logger

      Logger.error("Custode.Feed handler error (kept attached): " <> Exception.message(exception))

      :ok
  end

  defp do_handle_event(
         [provider, :run, outcome],
         _measurements,
         %{job: %{meta: %{"custode_kind" => "gate_review"}}},
         _config
       )
       when provider in [:oban_claude, :oban_codex] and outcome in [:stop, :exception],
       do: :ok

  defp do_handle_event(
         [:oban_codex, :run, :stop],
         _measurements,
         %{result: %CodexWrapper.Result{success: false} = result} = meta,
         _config
       ) do
    record_failure(meta, result)
  end

  defp do_handle_event(
         [:oban_claude, :run, :stop],
         _measurements,
         %{result: %ClaudeWrapper.Result{is_error: true} = result} = meta,
         _config
       ) do
    record_failure(meta, result)
  end

  defp do_handle_event([provider, :run, :stop], measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    out = structured(provider, meta.result) || %{}

    %{
      event: "turn",
      agent: agent_of(meta),
      directive: out["directive"],
      summary: out["summary"] || String.slice(text(provider, meta.result) || "", 0, 160),
      # An operator-origin turn is conversation, not telemetry (#138): the
      # full answer persists on the entry so a restart cannot strand it in
      # process memory. Sweep turns stay summary-only.
      response: prompt_response(provider, meta),
      cost_usd: round_cost(measurements.cost_usd),
      tokens: usage_total(provider, meta.result)
    }
    |> put_touched(out)
    |> put_action_class(out)
    |> put_repo(out)
    |> put_wake_reason(meta)
    |> put_hydration(meta)
    |> Custode.IntervalReports.decorate(out, provider, meta)
    |> Custode.Feed.record_turn(Custode.IntervalReports.ingestion_key(provider, meta))
  end

  defp do_handle_event([provider, :run, :exception], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    record_failure(meta, meta.error)
  end

  defp do_handle_event([provider, :agent, :transition], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    # The registry is already synced when transition telemetry fires, so the
    # gated payload is atomically readable here.
    case {meta.from, meta.to} do
      {_from, :awaiting_permission} ->
        Custode.Feed.record(
          %{
            event: "needs_approval",
            agent: meta.agent_id,
            action: gated(meta.agent_id, provider)
          },
          notify: true
        )

      {_from, :waiting_for_user} ->
        Custode.Feed.record(
          %{
            event: "needs_input",
            agent: meta.agent_id,
            question: gated(meta.agent_id, provider)
          },
          notify: true
        )

      {_from, :paused} ->
        Custode.Feed.record(%{event: "paused", agent: meta.agent_id})

      {:paused, :idle} ->
        Custode.Feed.record(%{event: "resumed", agent: meta.agent_id})

      _other ->
        :ok
    end
  end

  defp record_failure(meta, error) do
    {kind, detail} = error_facts(error)
    # One classification, made here at the turn boundary (#527): readers ask
    # "will the next beat fix this?" and must not each re-derive it from kind.
    category = Custode.TurnFailure.classify(error)

    entry =
      %{
        event: "turn_failed",
        agent: agent_of(meta),
        kind: kind,
        detail: detail,
        category: category,
        retryable: Custode.TurnFailure.retryable?(category)
      }
      |> put_wake_reason(meta)
      |> put_hydration(meta)

    Custode.Feed.record(
      entry,
      notify: true
    )

    # After the entry, so the streak it reads includes this failure (#543).
    # The turn's own transition to :running is long past, so NextBeat's
    # clear-on-running cannot take this back; the NEXT turn start does.
    Custode.BeatBackoff.after_failure(agent_of(meta), category)
  end

  # The schema'd sweep epilogue (#120 slice 2): what the turn touched arrives
  # as typed arrays, so cards and metrics read fields instead of fishing
  # numbers out of the prose summary. Absent -- or the wrong type, which a
  # model can still send past a schema -- means the key does not appear at
  # all, so an unschema'd turn's entry keeps exactly its old shape.
  defp put_touched(entry, out) do
    entry
    |> maybe_put(:prs, numbers(out["prs"]))
    |> maybe_put(:issues_touched, numbers(out["issues_touched"]))
  end

  # The class of action a gate-raising turn declared (#451). It rides on the
  # turn's own entry because this event is the only place custode sees the
  # whole structured result; `Custode.Gates` reads it back when the gate opens.
  defp put_action_class(entry, %{"directive" => "request_permission", "action_class" => class})
       when is_binary(class),
       do: Map.put(entry, :action_class, class)

  defp put_action_class(entry, _out), do: entry

  # The repository a gate-raising turn acts on (#542), carried the same way.
  # A value that is not `owner/name` does not appear at all.
  defp put_repo(entry, %{"directive" => "request_permission", "repo" => repo}),
    do: maybe_put_repo(entry, Custode.Repository.well_formed(repo))

  defp put_repo(entry, _out), do: entry

  defp maybe_put_repo(entry, nil), do: entry
  defp maybe_put_repo(entry, repo), do: Map.put(entry, :repo, repo)

  defp maybe_put(entry, _key, []), do: entry
  defp maybe_put(entry, key, numbers), do: Map.put(entry, key, numbers)

  defp put_hydration(entry, meta), do: Map.put(entry, :hydration, hydration(meta))

  defp put_wake_reason(entry, %{job: %{meta: %{"correlation_id" => "inbox:" <> _rest}}}),
    do: Map.put(entry, :wake_reason, "inbox_activity")

  defp put_wake_reason(entry, _meta), do: entry

  defp hydration(%{job: %{meta: meta}} = run_meta) when is_map(meta) do
    case meta["continuation_decision"] do
      "resume" -> "native_resume"
      decision when decision in ["fresh", "fresh_fallback"] -> context_hydration(run_meta)
      _other -> legacy_hydration(run_meta)
    end
  end

  defp hydration(meta), do: legacy_hydration(meta)

  defp context_hydration(meta) do
    if is_binary(context_args(meta)["custode_context_path"]), do: "packet", else: "fresh"
  end

  defp legacy_hydration(meta) do
    args = context_args(meta)

    cond do
      is_binary(args["resume"]) -> "native_resume"
      is_binary(args["custode_context_path"]) -> "packet"
      true -> "fresh"
    end
  end

  defp context_args(%{args: args}) when is_map(args), do: args
  defp context_args(%{job: %{args: args}}) when is_map(args), do: args
  defp context_args(_meta), do: %{}

  defp numbers(values) when is_list(values), do: Enum.filter(values, &is_integer/1)
  defp numbers(_other), do: []

  # The Error struct carries the actual diagnosis (message/stderr/exit code);
  # dropping it cost a debugging session (quakes' command_failed). Keep a
  # bounded slice in the feed entry.
  defp error_facts(%ClaudeWrapper.Error{} = error) do
    detail =
      [
        error.message,
        error.stderr && String.slice(error.stderr, 0, 300),
        error.stdout && String.slice(error.stdout, 0, 300)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" -- ")

    detail = if error.exit_code, do: "exit #{error.exit_code}: #{detail}", else: detail
    {error.kind, presence(detail)}
  end

  defp error_facts(%ClaudeWrapper.Result{is_error: true, result: result}) do
    detail = if is_binary(result), do: result |> String.slice(0, 300) |> presence()
    {:result_error, detail}
  end

  defp error_facts(%ObanCodex.Error{} = error) do
    detail =
      [error.message, inspect_reason(error.reason)] |> Enum.reject(&is_nil/1) |> Enum.join(" -- ")

    {error.kind, presence(detail)}
  end

  defp error_facts(%CodexWrapper.Result{} = result) do
    {:command_failed, Custode.CodexFailure.detail(result)}
  end

  defp error_facts(other), do: {:unknown, presence(inspect(other))}

  defp presence(""), do: nil
  defp presence(string), do: string

  defp round_cost(cost) when is_number(cost), do: Float.round(cost * 1.0, 4)
  defp round_cost(_other), do: 0.0

  defp inspect_reason(nil), do: nil
  defp inspect_reason(reason), do: reason |> inspect(printable_limit: 300) |> String.slice(0, 300)

  defp gated(agent_id, provider) do
    case Custode.Agents.status(agent_id, provider) do
      {:ok, {:awaiting_permission, %{description: description}}} -> description
      {:ok, {:waiting_for_user, question}} -> question
      _other -> nil
    end
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"

  # The feed carries a bounded answer preview for operator turns. The full
  # answer remains in the durable message receipt, independent of the report.
  @response_cap 16_384
  defp prompt_response(provider, %{job: %{meta: %{"origin" => "operator"}}, result: result}) do
    answer =
      case structured(provider, result) do
        nil -> Custode.ConversationAnswer.from_output(text(provider, result))
        output -> Custode.ConversationAnswer.explicit(output)
      end

    if answer, do: String.slice(answer, 0, @response_cap)
  end

  defp prompt_response(_provider, _meta), do: nil

  defp structured(:oban_claude, result), do: ObanClaude.structured(result)
  defp structured(:oban_codex, result), do: ObanCodex.structured(result)
  defp text(:oban_claude, result), do: result.result
  defp text(:oban_codex, result), do: ObanCodex.text(result)

  defp usage_total(:oban_claude, result) do
    case ClaudeWrapper.Result.usage(result) do
      nil -> nil
      usage -> usage.total
    end
  end

  defp usage_total(:oban_codex, result) do
    case ObanCodex.usage(result) do
      nil -> nil
      usage -> (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
    end
  end
end
