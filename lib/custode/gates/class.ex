defmodule Custode.Gates.Class do
  @moduledoc """
  The classes of action an approval gate can ask for (#451).

  A gate's detail is free prose, so "open a draft PR" and "merge to main" were
  the same kind of row and the 98% approval rate could only be read per agent.
  Whether a gate is a decision or a formality is a question about the CLASS of
  action, and answering it needs rows that carry one from the moment they are
  raised. The agent declares it, in the same structured result that raises the
  gate (`action_class`).

  This list is the single source for the directive schema's enum, the charter
  line, the metrics table and the console badge. It records; nothing here or
  anywhere else decides a gate by its class. The order is roughly how hard the
  action is to take back, easiest first.
  """

  @classes [
    {"comment", "comment on an issue or pull request"},
    {"file_issue", "file one or more issues"},
    {"implement", "write code on a branch and open a draft pull request"},
    {"pr_maintain", "push to, rebase, or fix CI on a pull request you already opened"},
    {"review", "post a review verdict on a pull request"},
    {"ready_pr", "mark a draft pull request ready for review"},
    {"merge", "merge a pull request"},
    {"roster", "add, edit or remove a routine, profile or sensor"},
    {"other", "anything else"}
  ]

  @ids Enum.map(@classes, &elem(&1, 0))

  @doc "Every class id, in order."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "Each class with its one-line meaning."
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @classes

  @doc """
  What to store for a declared value. A known class is itself; anything else
  a model sends past the schema is `"other"`; nothing declared is `nil`,
  which stays distinct from `"other"` so the rows that predate the field, or
  come from an agent that never says, are not counted as a class.

      iex> Custode.Gates.Class.normalize("ready_pr")
      "ready_pr"
      iex> Custode.Gates.Class.normalize("deploy")
      "other"
      iex> Custode.Gates.Class.normalize(nil)
      nil
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(class) when class in @ids, do: class
  def normalize(nil), do: nil
  def normalize(""), do: nil
  def normalize(_unknown), do: "other"

  @doc "The enum's description for the directive schema: every class and its meaning."
  @spec describe() :: String.t()
  def describe do
    meanings = Enum.map_join(@classes, "; ", fn {id, meaning} -> "#{id} = #{meaning}" end)
    "set when directive=request_permission: the class of the action. " <> meanings
  end
end
