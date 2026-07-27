defmodule Custode.Backlog do
  @moduledoc """
  How much work a served repo's board still holds (#274, shared with #246).

  One read with two callers asking opposite questions. The cadence advisor
  (#124) asks whether a repo carries ENOUGH open work to justify a faster
  cron; the dryness advisor (#274) asks whether it carries so LITTLE that the
  fleet should propose refilling it. Both read the same scoped verb, so the
  read lives here rather than privately inside whichever advisor needed it
  first.

  ## Why the error case is not zero

  This started as a private `backlog_size/1` in the cadence advisor whose
  contract was "0 on anything short of an answer". For demand that is right:
  no evidence, no ramp-up suggestion. For dryness it is dangerous, because 0
  is the TRIGGER -- a repo GitHub could not be read would look exactly like a
  repo with an empty board, and the fleet would propose a paid workflow run
  off a failed HTTP call.

  So `read/1` returns `{:ok, counts}` or `:error` and each caller decides what
  silence means. `size/1` keeps the old lenient contract for the demand half,
  which is the only place a missing answer may safely read as zero.

  ## What counts as workable

  `:open` is every open issue; `:workable` is the subset carrying the
  operator's `workable` label -- their mark for sliced-and-bounded work an
  agent can pick up without further design. A board can be long and still be
  dry: twenty open issues that all need design are no work for the fleet,
  which is why dryness reads the labelled count and not the total.
  """

  @workable_label "workable"

  @doc """
  A repo's board: `{:ok, %{open: n, workable: n}}`, or `:error` when the repo
  is nil, unserved, or could not be read. Zero tokens -- one scoped HTTP read.
  """
  def read(nil), do: :error

  def read(repo) do
    case Custode.Repository.list_issues(repo) do
      {:ok, issues} ->
        {:ok,
         %{
           open: length(issues),
           workable: Enum.count(issues, &workable?/1)
         }}

      _unreadable ->
        :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  @doc """
  The open-issue count, or 0 for a repo that cannot be read.

  The lenient read, for callers where a missing answer and an empty board
  mean the same thing (no demand evidence, so no suggestion). Anything that
  ACTS on emptiness wants `read/1` instead.
  """
  def size(repo) do
    case read(repo) do
      {:ok, %{open: open}} -> open
      :error -> 0
    end
  end

  defp workable?(issue) do
    @workable_label in (Map.get(issue, :labels) || [])
  end
end
