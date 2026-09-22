defmodule Custode.GateReviewJob do
  @moduledoc "Durable delivery for one cross-provider gate review."

  use Oban.Worker,
    queue: :agents,
    max_attempts: 1,
    unique: [fields: [:worker, :args], period: :infinity]

  alias Custode.Gates.CrossProviderReview

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"gate_id" => gate_id}} = job) do
    CrossProviderReview.run(gate_id, job: job)
    :ok
  end
end
