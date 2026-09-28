defmodule Custode.InboxWakeJob do
  @moduledoc "Oban kickoff for a durable inbox wake."

  use Oban.Worker, queue: :ticks, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"routine_id" => routine_id, "wake_id" => wake_id}})
      when is_binary(routine_id) and is_binary(wake_id) do
    Custode.InboxWakes.dispatch(routine_id, wake_id)
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_inbox_wake}
end
