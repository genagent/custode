defmodule Custode.Panels do
  @moduledoc """
  Agent-authored panels, gated (#100 v1). An agent proposes HTML for a
  panel on its own dashboard page via `set_panel`; the operator approves or
  rejects it; only an approved version renders, and only ever inside a
  locked-down `<iframe sandbox>` (the BEAM executes nothing).

  Storage is an append-only log of versions (`Panel` rows), so provenance
  survives and a rejected proposal never silently replaces the approved
  view. The "current" panel for a routine is its latest approved version; a
  "pending" proposal is a later unresolved one.

  The mode gate (`config :custode, :agent_panels`):

    * `:off` -- the `set_panel` tool is not even in the allowlist (verb-level
      denial, not prompt hope); agents cannot propose panels at all.
    * `:gated` (default) -- a proposal lands as `pending`; the operator
      approves it on the agent page.
    * `:auto` -- a proposal is approved on arrival (for a routine the
      operator trusts; the mode is global for v1).

  Security note: the HTML is untrusted. It is rendered ONLY through the
  sandboxed iframe in the LiveView, never interpolated into the page
  otherwise (not in previews, not in feed cards). See
  `CustodeWeb` for the single render site.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  # A generous cap: panels are markup, not payloads; this only guards against
  # a pathological fragment bloating a db row.
  @max_bytes 20_000

  defmodule Panel do
    @moduledoc false
    use Ecto.Schema

    schema "agent_panels" do
      field(:routine_id, :string)
      field(:html, :string)
      field(:status, :string, default: "pending")
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc "The panels mode: `:off`, `:gated` (default), or `:auto`."
  def mode, do: Application.get_env(:custode, :agent_panels, :gated)

  @doc """
  Propose a panel version (`set_panel`). Lands `pending` under `:gated`,
  `approved` under `:auto`. Returns `{:error, :too_large}` past the byte cap
  and `{:error, :panels_off}` when the mode is `:off`.
  """
  def set(routine_id, html) when is_binary(html) do
    cond do
      mode() == :off ->
        {:error, :panels_off}

      byte_size(html) > @max_bytes ->
        {:error, :too_large}

      true ->
        status = if mode() == :auto, do: "approved", else: "pending"
        row = Repo.insert!(%Panel{routine_id: routine_id, html: html, status: status})

        Custode.Feed.record(%{
          event: "panel_updated",
          agent: routine_id,
          summary: "panel #{status}"
        })

        {:ok, row}
    end
  end

  @doc "The latest APPROVED panel html for a routine, or nil."
  def current(routine_id) do
    case latest(routine_id, "approved") do
      %Panel{html: html} -> html
      nil -> nil
    end
  end

  @doc """
  The latest PENDING proposal (newer than any approved version), or nil.
  A pending row older than the current approved one has been superseded and
  is not surfaced.
  """
  def pending(routine_id) do
    pending = latest(routine_id, "pending")
    approved = latest(routine_id, "approved")

    cond do
      is_nil(pending) -> nil
      is_nil(approved) -> pending.html
      pending.id > approved.id -> pending.html
      true -> nil
    end
  end

  @doc "Approve the current pending proposal. No-op when none is pending."
  def approve(routine_id) do
    case unresolved_pending(routine_id) do
      %Panel{} = row ->
        row |> Ecto.Changeset.change(status: "approved") |> Repo.update!()

        Custode.Feed.record(%{
          event: "panel_updated",
          agent: routine_id,
          summary: "panel approved"
        })

        :ok

      nil ->
        :ok
    end
  end

  @doc "Reject the current pending proposal. No-op when none is pending."
  def reject(routine_id) do
    case unresolved_pending(routine_id) do
      %Panel{} = row ->
        row |> Ecto.Changeset.change(status: "rejected") |> Repo.update!()

        Custode.Feed.record(%{
          event: "panel_updated",
          agent: routine_id,
          summary: "panel rejected"
        })

        :ok

      nil ->
        :ok
    end
  end

  @doc """
  Whether a previous approved version exists to revert to (there is more than
  one approved version in the log).
  """
  def revertable?(routine_id) do
    Repo.aggregate(
      from(p in Panel, where: p.routine_id == ^routine_id and p.status == "approved"),
      :count
    ) > 1
  end

  @doc """
  Restore the previous approved version as the current one (one-click revert,
  #100). Re-appends the prior html as a fresh approved row so the log stays
  ordered. No-op when there is no prior version.
  """
  def revert(routine_id) do
    approved =
      Repo.all(
        from(p in Panel,
          where: p.routine_id == ^routine_id and p.status == "approved",
          order_by: [desc: p.id],
          limit: 2
        )
      )

    case approved do
      [_current, %Panel{html: prior}] ->
        Repo.insert!(%Panel{routine_id: routine_id, html: prior, status: "approved"})

        Custode.Feed.record(%{
          event: "panel_updated",
          agent: routine_id,
          summary: "panel reverted"
        })

        :ok

      _none ->
        :ok
    end
  end

  defp latest(routine_id, status) do
    Repo.one(
      from(p in Panel,
        where: p.routine_id == ^routine_id and p.status == ^status,
        order_by: [desc: p.id],
        limit: 1
      )
    )
  end

  # the pending row only if it is genuinely unresolved (newer than approved)
  defp unresolved_pending(routine_id) do
    pending = latest(routine_id, "pending")
    approved = latest(routine_id, "approved")

    cond do
      is_nil(pending) -> nil
      is_nil(approved) -> pending
      pending.id > approved.id -> pending
      true -> nil
    end
  end
end
