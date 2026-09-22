defmodule Custode.Operator.RoutineEdit do
  @moduledoc """
  Editing a routine from a form, in one place (#450).

  The agent page grew this as private functions: which fields a routine's
  edit form has, how a roster entry reads as form strings, how a submitted
  form becomes typed changes, and what a blank field means. The console edits
  the same routines, and two pages parsing a budget or a tag list separately
  is the drift `Custode.Operator.Actions` exists to prevent, so the logic
  lives here and both call it.

  The rules it keeps:

    * a field the operator did not touch is not a change
    * a BLANK field clears the override, so the routine inherits the profile
      or the default again (`nil` in the change set)
    * the first value that does not parse refuses the whole save, with a
      message that names the field

  Writes go through `Custode.Config.WriteBack`, which edits `routines.toml`
  and reloads the roster: a saved edit is live at the next minute, with no
  restart.
  """

  alias Custode.Config.Loader
  alias Custode.Config.WriteBack
  alias Custode.Routine.Effort

  @fields ~w(provider agent cron model effort max_budget_usd daily_budget_usd daily_budget_tokens timeout_ms max_turns prompt tags)

  @type strings :: %{String.t() => String.t()}

  @doc """
  Whether a save will MIGRATE the roster: with no roster file yet, the first
  write creates `routines.toml`, and from then on the file replaces the
  roster in application config wholesale. A form should say so before the
  operator saves, because it changes where the roster lives.
  """
  @spec migrates?() :: boolean()
  def migrates?, do: not File.exists?(Loader.target_path())

  @doc "The editable fields, in form order."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "A routine's raw roster entry as the strings its form starts from."
  @spec load(String.t()) :: {:ok, strings()} | {:error, term()}
  def load(routine_id) do
    with {:ok, raw} <- WriteBack.raw_entry(routine_id), do: {:ok, strings(raw)}
  end

  @doc "A raw roster entry (atom keys, typed values) as form strings."
  @spec strings(map()) :: strings()
  def strings(raw) do
    Map.new(@fields, fn field ->
      value =
        case Map.get(raw, String.to_existing_atom(field)) do
          nil -> ""
          :manual -> "manual"
          list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
          other -> to_string(other)
        end

      {field, value}
    end)
  end

  @doc """
  What changed between the strings the form started from and the ones
  submitted, as a typed change set for `WriteBack.update_routine/2`.
  """
  @spec changes(strings(), strings()) :: {:ok, map()} | {:error, String.t()}
  def changes(original, submitted) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn field, {:ok, changes} ->
      now = String.trim(submitted[field] || "")
      was = String.trim(original[field] || "")

      case change(field, now, was) do
        :unchanged -> {:cont, {:ok, changes}}
        {:ok, value} -> {:cont, {:ok, Map.put(changes, String.to_existing_atom(field), value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Save a submitted form. `{:ok, :unchanged}` when nothing changed, which is
  not an error and writes nothing.
  """
  @spec save(String.t(), strings(), strings()) ::
          {:ok, :unchanged | :saved} | {:error, term()}
  def save(routine_id, original, submitted) do
    case changes(original, submitted) do
      {:ok, changes} when changes == %{} ->
        {:ok, :unchanged}

      {:ok, changes} ->
        with {:ok, _path} <- WriteBack.update_routine(routine_id, changes), do: {:ok, :saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Remove a routine from the roster. Its notebook and workspace are kept: the
  roster says who is on the fleet, not what they knew.
  """
  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(routine_id, opts \\ []) do
    with {:ok, _path} <- WriteBack.remove_routine(routine_id) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: routine_id,
        summary:
          "remove_routine #{routine_id}: removed from the " <>
            "#{Keyword.get(opts, :surface, "dashboard")}, notebook kept"
      })

      :ok
    end
  end

  defp change(_field, same, same), do: :unchanged
  defp change(_field, "", _had_override), do: {:ok, nil}
  defp change(field, submitted, _original), do: parse(field, submitted)

  defp parse(field, value) when field in ~w(agent cron model prompt), do: {:ok, value}

  defp parse("provider", value) when value in ["claude", "codex"],
    do: {:ok, String.to_existing_atom(value)}

  defp parse("provider", value),
    do: {:error, "provider must be claude or codex, got #{inspect(value)}"}

  defp parse("effort", value), do: Effort.normalize(value)

  defp parse(field, value) when field in ~w(max_budget_usd daily_budget_usd) do
    case Float.parse(value) do
      {usd, ""} -> {:ok, usd}
      _other -> {:error, "#{field} must be a number, got #{inspect(value)}"}
    end
  end

  defp parse(field, value) when field in ~w(daily_budget_tokens timeout_ms max_turns) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _other -> {:error, "#{field} must be an integer, got #{inspect(value)}"}
    end
  end

  defp parse("tags", value) do
    {:ok,
     value
     |> String.split(",")
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.map(&String.to_atom/1)}
  end
end
