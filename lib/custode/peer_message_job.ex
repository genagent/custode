defmodule Custode.PeerMessageJob do
  @moduledoc "Durable outbox worker for peer inbox delivery and acknowledgment projection."

  use Oban.Worker,
    queue: :ticks,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :queue, :args],
      keys: [:message_id],
      states: [:available, :scheduled, :retryable]
    ]

  alias Custode.PeerMessageDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}} = job) when is_binary(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, _uuid} -> deliver(job, message_id)
      :error -> {:cancel, :invalid_message_id}
    end
  end

  def perform(_job), do: {:cancel, :invalid_peer_message_job}

  defp deliver(job, message_id) do
    case PeerMessageDelivery.deliver(message_id) do
      :ok -> :ok
      {:error, reason} when job.attempt >= job.max_attempts -> exhaust(message_id, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp exhaust(message_id, reason) do
    case PeerMessageDelivery.fail(message_id, {:delivery_retries_exhausted, reason}) do
      :ok -> {:cancel, :delivery_retries_exhausted}
      {:error, failure} -> {:error, failure}
    end
  end
end
