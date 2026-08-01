defmodule Custode.WorkspaceLeases.ReconcileJob do
  @moduledoc """
  Periodic workspace lease reconciliation (#430).

  `Custode.WorkspaceLeases.reconcile/1` marks expired or orphaned leases
  stale and retained. Before this worker it was invoked exactly once, as a
  boot Task, so a lease expiring while the node stayed up was never
  reclaimed until the next restart. The boot pass remains and covers leases
  orphaned by a hard stop; this cron line covers uptime.

  The schedule is `config :custode, :workspace_lease_reconcile_cron`
  (default every 15 minutes, well under the one-hour lease TTL; `false`
  disables the line). Every run that stales anything feeds a summary -- no
  silent reclamation.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  alias Custode.WorkspaceLeases

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case WorkspaceLeases.reconcile() do
      {:ok, []} ->
        :ok

      {:ok, leases} ->
        Custode.Feed.record(%{
          event: "janitor",
          agent: "custode",
          summary: "reconciled #{length(leases)} workspace lease(s) to stale"
        })

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
