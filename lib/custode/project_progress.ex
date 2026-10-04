defmodule Custode.ProjectProgress do
  @moduledoc """
  Read current evidence for one configured project routine.

  This grants the human operator and the caretaker's captured execution role
  access to direct operator exchanges. It grants no mutation authority and
  does not include peer-message bodies or change delegated-child ownership.

  A read without `:before` selects the newest exchanges, with full original
  prompts and results. Each page contains at most `:limit` exchanges (default
  5, maximum 20), ordered oldest first within that page. The opaque `before`
  cursor reads older exchanges at the original `snapshot_id` row cutoff;
  omit it before the next coordination decision to see new constraints.
  Existing rows' results and statuses may still advance after that cutoff.

  Execution, continuity, pending wake, attention and blocker are current
  independent reads even on older conversation pages. `attention` is the
  routine's ranked signal, including paused, budget and repository-check
  states; `blocker` is the narrower blocking question or approval. Neither
  includes resolving actions. Host, workflow and repository-wide infrastructure
  signals remain on the fleet attention surface. This is an observation, not
  an atomic snapshot or evidence of completed work.
  """

  alias Custode.Attention.Fleet
  alias Custode.{ConversationArcs, ExecutionFacts, InboxWakes, OperatorMessages, Routine}
  alias Custode.Operator.Authority

  @default_limit 5
  @max_limit 20

  @spec read(Authority.actor(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(actor, routine_id, opts \\ []) do
    with :ok <- authorize(actor),
         {:ok, routine} <- configured_routine(routine_id),
         {:ok, options} <- options(opts),
         {:ok, conversation} <- OperatorMessages.conversation(routine.id, options) do
      {:ok,
       %{
         schema_version: "custode.project_progress.v1",
         observed_at: DateTime.to_iso8601(DateTime.utc_now()),
         project: %{routine_id: routine.id, repo: routine.repo, role: to_string(routine.role)},
         links: %{
           conversation: "/agents/#{URI.encode(routine.id, &URI.char_unreserved?/1)}/conversation"
         },
         execution: execution(routine),
         continuity: ConversationArcs.read_model(routine.id),
         pending_wake: InboxWakes.read_model(routine.id),
         reports: Custode.IntervalReports.recent(routine.id, options[:limit]),
         attention: Fleet.signals_by_id() |> Map.get(routine.id) |> signal_facts(),
         blocker: routine.id |> Fleet.blocking_signal() |> signal_facts(),
         conversation:
           Map.put(conversation, :page, if(options[:before], do: "older", else: "latest"))
       }}
    end
  end

  defp authorize(%{kind: :routine, id: id}) when not is_binary(id) or id == "",
    do: {:error, "identity: project progress requires a nonempty routine identity"}

  defp authorize(actor), do: Authority.fleet_control(actor)

  defp configured_routine(id) when is_binary(id) and id != "" do
    case Routine.get(id) do
      nil -> {:error, :unknown_routine}
      routine -> {:ok, routine}
    end
  end

  defp configured_routine(_id), do: {:error, :invalid_routine_id}

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :before])) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      validate_options(Keyword.get(opts, :limit, @default_limit), Keyword.get(opts, :before))
    else
      {:error, :invalid_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp validate_options(limit, _before)
       when not is_integer(limit) or limit < 1 or limit > @max_limit,
       do: {:error, {:invalid_limit, limit}}

  defp validate_options(_limit, before) when not is_nil(before) and not is_binary(before),
    do: {:error, {:invalid_before, before}}

  defp validate_options(limit, before), do: {:ok, [limit: limit, before: before]}

  defp execution(routine) do
    routine.id
    |> ExecutionFacts.read(routine: routine)
    |> Map.update!(:live_error, &error_value/1)
  end

  defp error_value(value) when is_nil(value) or is_binary(value) or is_atom(value), do: value
  defp error_value(value), do: inspect(value)

  defp signal_facts(nil), do: nil

  defp signal_facts(signal) do
    Map.take(signal, [:subject, :kind, :group, :urgency, :headline, :detail, :raised_at])
  end
end
