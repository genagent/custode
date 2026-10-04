defmodule Custode.HelperRecords do
  @moduledoc "Retained helper navigation, separate from the active ownership registry."
  import Ecto.Query, only: [from: 2]
  alias Custode.{OperatorMessage, OperatorMessages, Repo}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    schema "helper_records" do
      field(:agent_id, :string)
      field(:parent, :string)
      field(:spawned_at, :utc_datetime_usec)
      field(:removed_at, :utc_datetime_usec)
    end
  end

  @doc false
  def spawn!(agent, parent) do
    remove!(agent)
    Repo.insert!(%Row{agent_id: agent, parent: parent, spawned_at: DateTime.utc_now()})
  end

  @doc false
  def remove!(agent) do
    Repo.update_all(from(r in Row, where: r.agent_id == ^agent and is_nil(r.removed_at)),
      set: [removed_at: DateTime.utc_now()]
    )
  end

  @doc "Capture a host-owned spawn epoch; old unaligned registry rows never infer an epoch."
  def publication_reference(agent_id) do
    query =
      from(spec in Custode.SubAgents.Row,
        left_join: row in Row,
        on:
          row.agent_id == spec.agent_id and row.parent == spec.parent and
            row.spawned_at == spec.spawned_at and is_nil(row.removed_at),
        where: spec.agent_id == ^agent_id,
        order_by: [desc: row.id],
        limit: 1,
        select: {spec, row}
      )

    case Repo.one(query) do
      nil ->
        {:error, "current_helper_unavailable"}

      {spec, row} ->
        {:ok,
         %{
           parent: spec.parent,
           recorded_session_id: spec.session_id,
           helper_epoch:
             if(row,
               do: %{
                 record_id: row.id,
                 agent_id: row.agent_id,
                 parent: row.parent,
                 spawned_at: DateTime.to_iso8601(row.spawned_at)
               }
             )
         }}
    end
  end

  @doc "Read one retained epoch only for the human or its currently authorized original parent."
  def read_epoch(actor, %{
        "record_id" => id,
        "agent_id" => agent,
        "parent" => parent,
        "spawned_at" => spawned
      })
      when is_integer(id) do
    with %Row{agent_id: ^agent, parent: ^parent} = row <- Repo.get(Row, id),
         true <- DateTime.to_iso8601(row.spawned_at) == spawned,
         :ok <- epoch_authority(actor, parent) do
      result = entry(row, actor)

      receipts =
        for receipt <- Enum.take(result.receipts, 3),
            do:
              receipt
              |> Map.put(:brief_preview, brief(receipt.message_id))
              |> Map.update!(:result_preview, &bounded/1)

      reports =
        for report <- Enum.take(result.reports, 2), do: Map.update!(report, :summary, &bounded/1)

      {:ok,
       %{
         result
         | receipts: receipts,
           reports: reports,
           has_more_receipts: result.has_more_receipts or length(result.receipts) > 3
       }}
    else
      {:error, _} = error -> error
      _missing -> {:error, "retained_helper_epoch_unavailable"}
    end
  end

  def read_epoch(_actor, _reference), do: {:error, "retained_helper_epoch_unavailable"}

  defp epoch_authority(%{kind: :operator}, _parent), do: :ok

  defp epoch_authority(%{kind: :routine, id: parent}, parent) do
    case Custode.AgentHandoff.authorization_routine(parent) do
      {:ok, _} -> :ok
      _ -> {:error, "current_original_parent_unavailable"}
    end
  end

  defp epoch_authority(_actor, _parent), do: {:error, "helper_details_not_granted"}

  defp brief(id) do
    case Repo.get_by(OperatorMessage, message_id: id) do
      nil -> nil
      message -> bounded(message.prompt)
    end
  end

  defp bounded(nil), do: nil
  defp bounded(text) when byte_size(text) <= 1000, do: text

  defp bounded(text) do
    prefix = binary_part(text, 0, 1000)
    if String.valid?(prefix), do: prefix, else: trim_incomplete(prefix)
  end

  defp trim_incomplete(prefix) do
    shorter = binary_part(prefix, 0, byte_size(prefix) - 1)
    if String.valid?(shorter), do: shorter, else: trim_incomplete(shorter)
  end

  @doc "Read bounded retained helpers and their exact parent-authored message receipts."
  def for_parent(parent, actor) do
    rows = Repo.all(from(r in Row, where: r.parent == ^parent, order_by: [desc: r.id], limit: 21))

    %{
      entries: Enum.map(Enum.take(rows, 20), &entry(&1, actor)),
      has_more: length(rows) > 20,
      source: "helper_records+operator_messages",
      observed_at: now(),
      settlement: "not_observed"
    }
  end

  defp entry(row, actor) do
    next =
      Repo.one(
        from(r in Row,
          where: r.agent_id == ^row.agent_id and r.id > ^row.id,
          order_by: r.id,
          limit: 1,
          select: r.spawned_at
        )
      )

    query =
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^row.agent_id and m.caller_kind == "routine" and
            m.caller_id == ^row.parent and m.inserted_at >= ^row.spawned_at,
        order_by: [desc: m.id],
        limit: 21
      )

    query = if next, do: from(m in query, where: m.inserted_at < ^next), else: query
    messages = Repo.all(query)

    %{
      record_id: row.id,
      agent_id: row.agent_id,
      parent: row.parent,
      spawned_at: DateTime.to_iso8601(row.spawned_at),
      removed_at: if(row.removed_at, do: DateTime.to_iso8601(row.removed_at)),
      registry_state: if(row.removed_at, do: "removed", else: "recorded"),
      settlement: "not_observed",
      has_more_receipts: length(messages) > 20,
      receipts: Enum.map(Enum.take(messages, 20), &receipt(&1, actor)),
      reports: reports(row, next),
      owner_link: "/agents/#{URI.encode(row.parent, &URI.char_unreserved?/1)}/conversation"
    }
  end

  defp receipt(message, actor) do
    visible = OperatorMessages.visible_to?(message, actor)

    message
    |> OperatorMessages.public()
    |> Map.drop([:result, :error, :detail])
    |> Map.put(:result_preview, if(visible, do: preview(message.result)))
    |> Map.put(
      :result_availability,
      if(visible, do: "exact_receipt", else: "requires_original_parent_or_human")
    )
    |> Map.put(
      :result_reference,
      %{tool: "await_agent", arguments: %{message_id: message.message_id, timeout_ms: 0}}
    )
  end

  defp preview(%{"output" => text}) when is_binary(text), do: String.slice(text, 0, 2000)
  defp preview(_result), do: nil

  defp reports(row, next) do
    query =
      from(f in Custode.Feed.Entry,
        where:
          f.agent == ^row.agent_id and f.event in ["turn", "turn_failed"] and
            f.at >= ^row.spawned_at,
        order_by: [desc: f.id],
        limit: 5
      )

    query = if next, do: from(f in query, where: f.at < ^next), else: query

    Repo.all(query)
    |> Enum.map(fn entry ->
      decoded = Jason.decode!(entry.entry)

      %{
        feed_entry_id: entry.id,
        evidence: "agent_authored",
        at: decoded["at"],
        summary: String.slice(decoded["summary"] || "", 0, 2000),
        identity:
          Map.take(
            decoded,
            ~w(provider job_id job_attempt agent_generation agent_turn_id correlation_id)
          ),
        result_reference: %{tool: "feed_tail", arguments: %{agent_id: row.agent_id, n: 5}}
      }
    end)
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
