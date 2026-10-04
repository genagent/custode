defmodule Custode.ContextReceipts do
  @moduledoc "Exact historical tool text, separating preparation, server emission and unknown model receipt."
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Custode.{ExecutionFacts, Repo, SubjectDocuments}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:receipt_id, :string, autogenerate: false}
    schema "context_receipts" do
      field(:actor_key, :string)
      field(:root_id, :string)
      field(:path, :string)
      field(:record, :map)
      field(:payload, :string)
      field(:at, :utc_datetime_usec)
    end
  end

  @doc "Prepare only bounded document reads, when a verified HTTP request nonce is present."
  def prepare(%{assigns: assigns}, %{"action" => "read"} = params, document) do
    case assigns do
      %{custode_identity: actor, custode_delivery_id: id} when is_binary(id) ->
        text = JSON.encode!(Map.put(document, "context_receipt_id", id))

        record = %{
          "actor" => json(actor),
          "revision" => document["revision"],
          "state" => "prepared",
          "payload_sha256" => hash(text),
          "bytes" => byte_size(text),
          "tokens" => nil,
          "model_received" => "unknown",
          "native_hidden_context" => "unknown",
          "instruction_layers" => "unavailable_on_this_tool_seam",
          "observed_execution" => execution(actor),
          "execution_binding" => "unknown_observation_not_session_attribution",
          "expires_at" => DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_iso8601()
        }

        {:ok, _} =
          Repo.transaction(
            fn ->
              Repo.insert!(%Row{
                receipt_id: id,
                actor_key: actor_key(actor),
                root_id: params["root_id"],
                path: params["path"],
                record: record,
                payload: text,
                at: DateTime.utc_now()
              })

              prune_payloads(actor_key(actor))
            end,
            mode: :immediate
          )

        {:ok, text}

      _direct_call ->
        :unavailable
    end
  end

  def prepare(_frame, _params, _document), do: :unavailable

  @doc "Observe the completed JSON send, checking the exact tool text against its prepared receipt."
  def emitted(%Plug.Conn{state: :sent, status: 200} = conn) do
    id = conn.assigns[:custode_delivery_id]

    with true <- is_binary(id),
         %Row{payload: payload} = row <- Repo.get(Row, id),
         true <- is_binary(payload),
         {:ok, %{"result" => %{"content" => [%{"text" => ^payload}]}}} <-
           Jason.decode(
             IO.iodata_to_binary(conn.assigns[:custode_response_body] || conn.resp_body || "")
           ) do
      row
      |> Ecto.Changeset.change(
        record:
          Map.merge(row.record, %{
            "state" => "server_emitted",
            "emitted_at" => DateTime.to_iso8601(DateTime.utc_now())
          })
      )
      |> Repo.update!()
    else
      _unproven -> :ok
    end

    conn
  rescue
    error ->
      Logger.warning("Context receipt emission remains unconfirmed: #{inspect(error.__struct__)}")
      conn
  end

  def emitted(conn), do: conn

  def read(actor, id) do
    with %Row{} = row <- Repo.get(Row, id),
         :ok <- visible(actor, row),
         :ok <- SubjectDocuments.authorize_read(actor, row.root_id, row.path) do
      expired =
        DateTime.compare(
          DateTime.utc_now(),
          DateTime.from_iso8601(row.record["expires_at"]) |> elem(1)
        ) != :lt

      {:ok,
       Map.merge(row.record, %{
         "receipt_id" => id,
         "root_id" => row.root_id,
         "path" => row.path,
         "payload_state" => if(expired or is_nil(row.payload), do: "expired", else: "retained"),
         "exact_tool_text" => if(expired, do: nil, else: row.payload)
       })}
    else
      nil -> {:error, "context_receipt_unavailable"}
      error -> error
    end
  end

  def list(actor, root_id) do
    with :ok <- SubjectDocuments.authorize_root(actor, root_id), do: scoped_list(actor, root_id)
  end

  defp scoped_list(actor, root_id) do
    rows =
      Repo.all(
        from(row in Row,
          where: row.root_id == ^root_id,
          order_by: [desc: row.at, asc: row.receipt_id],
          limit: 100
        )
      )

    records =
      for row <- rows,
          {:ok, record} <- [read(actor, row.receipt_id)],
          do: Map.delete(record, "exact_tool_text")

    {:ok, records}
  end

  defp visible(%{kind: :operator}, _row), do: :ok

  defp visible(%{kind: kind, id: id} = actor, row)
       when kind in [:routine, :sub_agent] and is_binary(id) do
    if actor_key(actor) == row.actor_key, do: :ok, else: {:error, "context_receipt_not_granted"}
  end

  defp visible(_actor, _row), do: {:error, "unauthenticated"}

  defp prune_payloads(key) do
    keep =
      Repo.all(
        from(row in Row,
          where: row.actor_key == ^key,
          order_by: [desc: row.at, desc: row.receipt_id],
          limit: 100,
          select: row.receipt_id
        )
      )

    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)

    Repo.update_all(
      from(row in Row,
        where:
          row.actor_key == ^key and
            (row.receipt_id not in ^keep or row.at < ^cutoff)
      ),
      set: [payload: nil]
    )
  end

  defp execution(%{kind: :routine, id: id}), do: json(ExecutionFacts.read(id))
  defp execution(_actor), do: nil
  defp actor_key(actor), do: "#{actor.kind}:#{actor.id}"
  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
