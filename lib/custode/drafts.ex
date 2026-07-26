defmodule Custode.Drafts do
  @moduledoc """
  The batch filing gate (#241, design/006 slice 1): one gate per steward
  sweep covering the issues it drafted, individually droppable.

  ## Why the batch lives in a table

  The gate grammar underneath is strictly one-action. `request_permission`
  carries a description string, `approve_action/2` carries an action id and
  nothing else, and `reject_action/3` carries a reason back. There is
  nowhere in that grammar for "approve these four, drop the fifth" to land,
  and widening it would put a per-item decision into a primitive every gate
  in the fleet shares.

  So the batch is a record and the gate stays one action:

  1. the steward calls `draft/3` with its findings -- rows, no GitHub write;
  2. it raises ONE `request_permission` listing them;
  3. while that gate is open the operator drops individual entries on the
     agent page (`drop/2`, reversible with `restore/2`);
  4. the approved continuation calls `file/2`, which files exactly the rows
     still marked `drafted` and skips every dropped one.

  Dropping is therefore a decision on the record rather than on the gate,
  which also means it survives a restart and reads back afterwards: the
  batch says what was proposed, what the operator dropped, and what was
  filed. A rejected gate leaves the whole batch unfiled and readable.

  ## What this module does not decide

  Whether a title is conventional and whether the repo is served stays with
  `Custode.Repository`, which is where every other GitHub write is checked.
  `file/2` therefore reports per-entry outcomes: a refusal marks that one
  row `failed` with the policy message and the rest of the batch still
  files. Drafting deliberately does not pre-check, so there is exactly one
  place where a filing policy lives.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  # A steward sweep that finds more than this has stopped triaging and
  # started dumping; the cap makes that a refusal rather than a board flood.
  @max_entries 25
  @max_body_bytes 20_000

  defmodule Draft do
    @moduledoc false
    use Ecto.Schema

    schema "issue_drafts" do
      field(:batch_id, :string)
      field(:routine_id, :string)
      field(:repo, :string)
      field(:title, :string)
      field(:body, :string)
      field(:labels, :string)
      field(:status, :string, default: "drafted")
      field(:issue_url, :string)
      field(:note, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc """
  Draft a batch of issues for one repo. Writes rows only -- nothing reaches
  GitHub until `file/2` runs on an approved continuation.

  `entries` is a list of maps with `:title` (required), `:body` and
  `:labels`. Returns `{:ok, %{batch_id: id, entries: rows}}`.
  """
  def draft(routine_id, repo, entries) when is_list(entries) do
    with :ok <- check_count(entries),
         {:ok, normalized} <- normalize(entries) do
      batch_id = batch_id()

      rows =
        for entry <- normalized do
          Repo.insert!(%Draft{
            batch_id: batch_id,
            routine_id: routine_id,
            repo: repo,
            title: entry.title,
            body: entry.body,
            labels: Jason.encode!(entry.labels)
          })
        end

      Custode.Feed.record(%{
        event: "repo_verb",
        agent: routine_id,
        summary: "drafted #{length(rows)} issue(s) for #{repo}, awaiting the filing gate"
      })

      {:ok, %{batch_id: batch_id, entries: rows}}
    end
  end

  @doc "Every row of a batch, oldest first."
  def entries(batch_id) do
    Repo.all(from(d in Draft, where: d.batch_id == ^batch_id, order_by: [asc: d.id]))
  end

  @doc """
  The routine's newest UNFILED batch, or nil. A batch stops being pending
  once any of its rows has been filed (or failed to file): the operator's
  window for dropping entries closes when the continuation runs.
  """
  def pending_batch(routine_id) do
    latest =
      Repo.one(
        from(d in Draft,
          where: d.routine_id == ^routine_id,
          order_by: [desc: d.id],
          limit: 1,
          select: d.batch_id
        )
      )

    case latest && entries(latest) do
      nil -> nil
      rows -> if Enum.all?(rows, &(&1.status in ["drafted", "dropped"])), do: rows
    end
  end

  @doc """
  Drop one entry from a pending batch -- the operator's per-item decision
  while the batch's gate is open. Refuses once the row has been filed, so a
  late click cannot rewrite what actually happened.
  """
  def drop(draft_id, note \\ nil), do: set_status(draft_id, "dropped", note)

  @doc "Undo a drop, putting the entry back in the batch."
  def restore(draft_id), do: set_status(draft_id, "drafted", nil)

  @doc """
  File the kept entries of a batch -- the approved continuation's verb.

  Files every row still marked `drafted`, in order, through
  `Custode.Repository.open_issue/2` (so policy applies exactly as it does to
  a hand-written `repo_open_issue`). Dropped rows are skipped and stay
  dropped. A row that GitHub or policy refuses is marked `failed` with the
  message and the rest of the batch still files.

  Idempotent by construction: a filed row is no longer `drafted`, so a
  re-run of the same batch files nothing twice.
  """
  def file(routine_id, batch_id) do
    case entries(batch_id) do
      [] ->
        {:error, :unknown_batch}

      [%Draft{routine_id: owner} | _] when owner != routine_id ->
        {:error, :not_yours}

      rows ->
        results = Enum.map(rows, &file_one/1)
        summarize(routine_id, batch_id, results)
    end
  end

  @doc "Decode a row's labels back into a list."
  def labels(%Draft{labels: nil}), do: []
  def labels(%Draft{labels: json}), do: Jason.decode!(json)

  defp file_one(%Draft{status: "dropped"} = row), do: {:dropped, row}

  defp file_one(%Draft{status: "drafted"} = row) do
    attrs = %{title: row.title, body: row.body, labels: labels(row)}

    case Custode.Repository.open_issue(row.repo, attrs) do
      {:ok, issue} ->
        {:filed, update!(row, status: "filed", issue_url: issue["html_url"])}

      {:error, message} ->
        {:failed, update!(row, status: "failed", note: to_string(message))}
    end
  end

  # already filed or already failed: a re-run leaves it exactly as it is
  defp file_one(%Draft{} = row), do: {:already, row}

  defp summarize(routine_id, batch_id, results) do
    filed = for {:filed, row} <- results, do: %{title: row.title, url: row.issue_url}
    failed = for {:failed, row} <- results, do: %{title: row.title, error: row.note}
    dropped = for {:dropped, row} <- results, do: row.title

    Custode.Feed.record(%{
      event: "repo_verb",
      agent: routine_id,
      summary:
        "filed #{length(filed)} of #{length(results)} drafted issue(s)" <>
          droppage(dropped) <> failure(failed)
    })

    {:ok, %{batch_id: batch_id, filed: filed, dropped: dropped, failed: failed}}
  end

  defp droppage([]), do: ""
  defp droppage(dropped), do: ", #{length(dropped)} dropped by the operator"

  defp failure([]), do: ""
  defp failure(failed), do: ", #{length(failed)} refused"

  defp set_status(draft_id, status, note) do
    case Repo.get(Draft, draft_id) do
      nil ->
        {:error, :not_found}

      %Draft{status: current} when current not in ["drafted", "dropped"] ->
        {:error, :already_filed}

      %Draft{} = row ->
        {:ok, update!(row, status: status, note: note)}
    end
  end

  defp update!(row, changes), do: row |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp check_count([]), do: {:error, :empty}
  defp check_count(entries) when length(entries) > @max_entries, do: {:error, :too_many}
  defp check_count(_entries), do: :ok

  defp normalize(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_one(entry) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_one(entry) do
    title = entry |> get(:title) |> to_string() |> String.trim()
    body = entry |> get(:body) |> to_string()
    labels = entry |> get(:labels) |> List.wrap() |> Enum.map(&to_string/1)

    cond do
      title == "" -> {:error, :missing_title}
      byte_size(body) > @max_body_bytes -> {:error, :body_too_large}
      true -> {:ok, %{title: title, body: body, labels: labels}}
    end
  end

  defp get(entry, key), do: Map.get(entry, key) || Map.get(entry, to_string(key))

  defp batch_id do
    "batch-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  @doc "The per-batch entry cap, for the tool's error text and the docs."
  def max_entries, do: @max_entries
end
