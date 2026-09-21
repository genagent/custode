defmodule Custode.Feed.Ingest do
  @moduledoc """
  The telemetry half of the feed (#92 item 5): armored handlers that turn
  oban_claude events into `Custode.Feed.record/2` calls. Storage and
  queries live in `Custode.Feed`; notification dispatch in
  `Custode.Feed.Notify`.
  """

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception]
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

  defp do_handle_event([:oban_claude, :run, :stop], measurements, meta, _config) do
    out = ObanClaude.structured(meta.result) || %{}
    usage = ClaudeWrapper.Result.usage(meta.result)

    %{
      event: "turn",
      agent: agent_of(meta),
      directive: out["directive"],
      summary: out["summary"] || String.slice(meta.result.result || "", 0, 160),
      # An operator-origin turn is conversation, not telemetry (#138): the
      # full answer persists on the entry so a restart cannot strand it in
      # process memory. Sweep turns stay summary-only.
      response: prompt_response(meta),
      cost_usd: Float.round(measurements.cost_usd, 4),
      tokens: usage && usage.total
    }
    |> put_touched(out)
    |> put_action_class(out)
    |> put_repo(out)
    |> Custode.Feed.record()
  end

  defp do_handle_event([:oban_claude, :run, :exception], _measurements, meta, _config) do
    {kind, detail} = error_facts(meta.error)
    # One classification, made here at the turn boundary (#527): readers ask
    # "will the next beat fix this?" and must not each re-derive it from kind.
    category = Custode.TurnFailure.classify(meta.error)

    Custode.Feed.record(
      %{
        event: "turn_failed",
        agent: agent_of(meta),
        kind: kind,
        detail: detail,
        category: category,
        retryable: Custode.TurnFailure.retryable?(category)
      },
      notify: true
    )

    # After the entry, so the streak it reads includes this failure (#543).
    # The turn's own transition to :running is long past, so NextBeat's
    # clear-on-running cannot take this back; the NEXT turn start does.
    Custode.BeatBackoff.after_failure(agent_of(meta), category)
  end

  defp do_handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    # The registry is already synced when transition telemetry fires, so the
    # gated payload is atomically readable here.
    case {meta.from, meta.to} do
      {_from, :awaiting_permission} ->
        Custode.Feed.record(
          %{event: "needs_approval", agent: meta.agent_id, action: gated(meta.agent_id)},
          notify: true
        )

      {_from, :waiting_for_user} ->
        Custode.Feed.record(
          %{event: "needs_input", agent: meta.agent_id, question: gated(meta.agent_id)},
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

  defp error_facts(other), do: {:unknown, presence(inspect(other))}

  defp presence(""), do: nil
  defp presence(string), do: string

  defp gated(agent_id) do
    case Custode.Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{description: description}}} -> description
      {:ok, {:waiting_for_user, question}} -> question
      _other -> nil
    end
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"

  # The full response text for an operator-origin turn, nil otherwise.
  # Capped generously: prompt answers are prose, not payloads, and the cap
  # only guards against a pathological turn flooding a feed row.
  @response_cap 16_384
  defp prompt_response(%{job: %{meta: %{"origin" => "operator"}}, result: result}) do
    # a schema'd run's raw text IS the directive JSON, and the whole answer
    # already persists uncapped in the entry's summary -- echoing the blob
    # here just renders the answer twice, once as escaped JSON (#201)
    case {ObanClaude.structured(result), result.result} do
      {%{}, _raw} -> nil
      {nil, text} when is_binary(text) and text != "" -> String.slice(text, 0, @response_cap)
      _other -> nil
    end
  end

  defp prompt_response(_meta), do: nil
end
