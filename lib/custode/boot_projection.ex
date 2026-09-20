defmodule Custode.BootProjection do
  @moduledoc """
  Running a projection at boot without letting one bad row take the boot log
  down with it (#476).

  Both legacy projections (`Custode.LegacyMissionProjection`,
  `Custode.LegacyRoleBindingProjection`) project every routine they can and
  report the ones they could not. Their bang versions turn any failure into a
  raise, which is right for a caller that needs all-or-nothing and wrong for
  the boot Task: a repository GitHub refuses is an environmental condition.
  On the first live boot after design/010 it was `redis/redisctl`, 403 behind
  an org's SAML SSO, and the result was three kilobytes of HTTP response
  headers in an `[error]` on every boot, with the second projection skipped
  because it was chained after the first in one function.

  `run/2` logs one warning per routine that could not be projected and returns
  `:ok`.
  """

  require Logger

  @type report :: %{failures: [%{legacy_routine_id: String.t(), reason: term()}]}

  @doc """
  Run `project` (a zero-arity function returning `{:ok, _}` or
  `{:error, report}`) and log its failures under `label`.
  """
  @spec run(String.t(), (-> {:ok, term()} | {:error, report()})) :: :ok
  def run(label, project) when is_binary(label) and is_function(project, 0) do
    case project.() do
      {:ok, _responses} ->
        :ok

      {:error, %{failures: failures}} ->
        for %{legacy_routine_id: id, reason: reason} <- failures do
          Logger.warning("#{label} skipped #{id}: #{short(reason)}")
        end

        :ok
    end
  end

  @doc """
  A failure reason as one line a person can act on. Never the response body or
  headers: they are large, and they can carry authorization URLs.

      iex> Custode.BootProjection.short({:repository_identity_unavailable, "redis/redisctl", %{status: 403}})
      "repository identity unavailable for redis/redisctl (HTTP 403)"

      iex> Custode.BootProjection.short(:mission_missing)
      ":mission_missing"
  """
  @spec short(term()) :: String.t()
  def short({:repository_identity_unavailable, repo, %{status: status}}) when is_integer(status),
    do: "repository identity unavailable for #{repo} (HTTP #{status})"

  def short({:repository_identity_unavailable, repo, _error}),
    do: "repository identity unavailable for #{repo}"

  def short(reason), do: reason |> inspect(limit: 5, printable_limit: 120) |> String.slice(0, 200)
end
