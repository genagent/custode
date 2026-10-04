defmodule Custode.CurrentRun do
  @moduledoc "Independently observed run, input, and helper facts for operator clients."
  import Ecto.Query, only: [from: 2]
  alias Custode.{ExecutionFacts, HelperRecords, OperatorMessage, OperatorMessages, Repo, Routine}
  alias Custode.Operator.Authority

  @doc "Read current facts without starting work or granting helper control."
  def read(actor, id) do
    with :ok <- Authority.fleet_control(actor),
         {:ok, routine} <- routine(id) do
      execution = ExecutionFacts.read(id, routine: routine)
      execution = Map.update!(execution, :live_error, &error_value/1)

      {:ok,
       %{
         schema_version: "custode.current_run.v1",
         routine_id: id,
         observed_at: now(),
         consistency: "independent_observations",
         execution: %{
           facts: execution,
           observed_at: now(),
           source: "routine+provider_process+oban_jobs"
         },
         input: input(id),
         helpers: HelperRecords.for_parent(id, actor),
         plan: %{reference: nil, revision: nil, availability: "no_identified_document"},
         controls: %{
           pause: "locks_lifecycle_without_confirming_physical_settlement",
           queue_edit: "unavailable",
           queue_remove: "unavailable",
           recursive_cancel: "unavailable"
         }
       }}
    end
  end

  defp input(id) do
    query =
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^id and
            m.caller_kind == "operator" and
            m.status in ~w(queued executing waiting_for_input waiting_for_approval)
      )

    {:ok, {counts, rows}} =
      Repo.transaction(fn ->
        counts =
          Repo.all(
            from(m in query,
              group_by: [m.status, m.delivery],
              select: {m.status, m.delivery, count(m.id)}
            )
          )

        rows = Repo.all(from(m in query, order_by: [asc: m.id], limit: 21))
        {counts, rows}
      end)

    %{
      source: "operator_messages",
      observed_at: now(),
      queued: count(counts, "queued", "queued"),
      admitting: count(counts, "queued", "admitting"),
      executing: count(counts, "executing"),
      waiting_for_input: count(counts, "waiting_for_input"),
      waiting_for_approval: count(counts, "waiting_for_approval"),
      has_more_receipts: length(rows) > 20,
      receipts: Enum.map(Enum.take(rows, 20), &OperatorMessages.public_summary/1)
    }
  end

  defp count(rows, status, delivery \\ nil) do
    Enum.reduce(rows, 0, fn {s, d, count}, total ->
      if s == status and (is_nil(delivery) or d == delivery), do: total + count, else: total
    end)
  end

  defp routine(id) when is_binary(id) and id != "" do
    case Routine.get(id) do
      nil -> {:error, :unknown_routine}
      routine -> {:ok, routine}
    end
  end

  defp routine(_id), do: {:error, :invalid_routine_id}
  defp error_value(value) when is_nil(value) or is_binary(value) or is_atom(value), do: value
  defp error_value(value), do: inspect(value)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
