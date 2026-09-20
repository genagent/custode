defmodule Custode.Operator.RoutineNew do
  @moduledoc """
  Adding a routine from a form, in one place (#450).

  The fleet page grew this as private functions. The console adds agents too,
  and the same reasoning as `Custode.Operator.RoutineEdit` applies: two pages
  converting a form into a roster entry separately will come to disagree.

  The form is deliberately small: an id, optionally a profile (which supplies
  the role, model, rails and prompt), the repository and where it is checked
  out, tags, a cron, and a prompt for a bespoke agent. Everything else is
  inherited or edited afterwards.

  `preview/1` is the literal TOML `create/2` appends, so what the operator
  reads is what gets written.
  """

  alias Custode.Config.WriteBack

  @fields ~w(id profile repo working_dir tags cron prompt)

  @doc "The form's fields, in order."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "The profiles a new routine may name, for the form's menu."
  @spec profiles() :: [atom()]
  def profiles, do: Custode.Routine.profiles() |> Map.keys() |> Enum.sort()

  @doc """
  Form params (string keys, string values) as the write-back's attrs. Blank
  fields are left out, so the routine inherits them.
  """
  @spec attrs(map()) :: {:ok, map()} | {:error, String.t()}
  def attrs(params) do
    case String.trim(params["id"] || "") do
      "" ->
        {:error, "id is required"}

      id ->
        {:ok,
         %{id: id}
         |> put(params, "profile", &known_profile!/1)
         |> put(params, "cron")
         |> put(params, "repo")
         |> put(params, "working_dir")
         |> put(params, "workspace")
         |> put(params, "prompt")
         |> put(params, "tags", &tags/1)}
    end
  rescue
    ArgumentError -> {:error, "unknown profile #{inspect(params["profile"])}"}
  end

  @doc "The TOML a create would append, or why the form is not valid yet."
  @spec preview(map()) :: {:ok, String.t()} | {:error, String.t()}
  def preview(params) do
    with {:ok, attrs} <- attrs(params), do: {:ok, WriteBack.render_routine(attrs)}
  end

  @doc """
  Add the routine: the roster file and the live roster in one operation. It is
  live at once and scheduled at its next cron minute. Returns the new id.
  """
  @spec create(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(params, opts \\ []) do
    with {:ok, attrs} <- attrs(params),
         {:ok, path} <- WriteBack.add_routine(attrs) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: attrs.id,
        summary:
          "add_routine #{attrs.id}: created from the " <>
            "#{Keyword.get(opts, :surface, "dashboard")}, appended to #{path}"
      })

      {:ok, attrs.id}
    end
  end

  # An unknown profile is one that is not a KEY in the profile map, not merely
  # a string that fails to be an existing atom: membership keeps the guard
  # honest about unrelated atoms that happen to share the name. Either way it
  # raises ArgumentError, which `attrs/1` turns into the message.
  defp known_profile!(value) do
    atom = String.to_existing_atom(value)
    if Map.has_key?(Custode.Routine.profiles(), atom), do: atom, else: raise(ArgumentError)
  end

  defp tags(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  defp put(attrs, params, key, convert \\ & &1) do
    case String.trim(params[key] || "") do
      "" -> attrs
      value -> Map.put(attrs, String.to_existing_atom(key), convert.(value))
    end
  end
end
