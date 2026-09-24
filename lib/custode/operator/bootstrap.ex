defmodule Custode.Operator.Bootstrap do
  @moduledoc """
  The compact first read for an external operator session (#647, design/012).

  One call answers: which Custode instance is this, who am I to it and over
  which transport, what may I do, what shape is the fleet in, and which
  operations expand each part. The MCP tool is a thin wrapper; nothing here is
  specific to one surface.

  Every count comes from the source the rest of the application already reads:
  `Custode.Attention.Fleet` for attention groups, `Custode.Gates` and
  `Custode.Asks` for what is waiting on the operator, `Custode.Agents` for
  lifecycle state and `Custode.executing_turns/0` for running turns. The result
  holds no token, filesystem path, prompt text or provider transcript.

  The caller must be the human operator. `build/2` does not check that: the
  surface that invokes it does, through `Custode.Operator.Authority.human/1`.
  """

  alias Custode.{Asks, Gates, Installation, Routine}
  alias Custode.Attention.Fleet
  alias Custode.MCP.ToolPolicy

  @schema_version "custode.operator_bootstrap.v1"

  # {topic, tool}: the existing operations that expand each part of the brief.
  # Tool discovery stays authoritative for schemas.
  @expand [
    {"attention", "list_attention"},
    {"digest", "digest"},
    {"routines", "list_routines"},
    {"agent_status", "agent_status"},
    {"conversations", "agent_history"},
    {"gates", "list_gates"},
    {"questions", "list_asks"},
    {"spend", "spend_today"},
    {"recent_changes", "feed_tail"},
    {"executing_turns", "executing_turns"}
  ]

  @doc "The schema version stamped on every result."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  The bootstrap map for an authenticated operator.

  Options: `:transport` (`:mcp` | `:cli`, default `:mcp`) and `:verified`
  (whether the identity came from an authenticated request rather than a direct
  call, default `true`).
  """
  @spec build(%{required(:kind) => atom(), optional(:id) => String.t()}, keyword()) :: map()
  def build(%{kind: :operator} = caller, opts \\ []) do
    %{
      schema_version: @schema_version,
      installation: installation(),
      caller: %{
        kind: Atom.to_string(caller.kind),
        id: Map.get(caller, :id, "operator"),
        transport: opts |> Keyword.get(:transport, :mcp) |> to_string(),
        verified: Keyword.get(opts, :verified, true)
      },
      authority: %{
        scope: "all",
        endpoint: "main",
        tool_count: map_size(ToolPolicy.all())
      },
      fleet: fleet(),
      expand: for({topic, tool} <- @expand, do: %{topic: topic, tool: tool})
    }
  end

  defp installation do
    %{
      id: Installation.id(),
      custode_version: :custode |> Application.spec(:vsn) |> to_string(),
      host: host(),
      timezone: Application.get_env(:custode, :timezone)
    }
  end

  defp host do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _error -> nil
    end
  end

  defp fleet do
    routines = Routine.all()

    %{
      caretaker: caretaker(),
      routines: %{total: length(routines), by_state: by_state(routines)},
      executing_turns: length(Custode.executing_turns()),
      attention: attention(),
      open_gates: Gates.open_by_agent() |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
      open_asks: length(Asks.open())
    }
  end

  defp caretaker do
    case Custode.Operator.Actions.caretaker() do
      nil -> nil
      id -> %{id: id, state: state(id)}
    end
  end

  defp by_state(routines) do
    routines
    |> Enum.frequencies_by(&state(&1.id))
    |> Map.new(fn {state, count} -> {Atom.to_string(state), count} end)
  end

  defp state(routine_id) do
    case Custode.Agents.status(routine_id) do
      {:ok, status} -> Custode.state_of(status)
      _error -> :unknown
    end
  end

  defp attention do
    groups =
      for {group, signals} <- Fleet.by_group(),
          into: %{},
          do: {Atom.to_string(group), length(signals)}

    %{total: groups |> Map.values() |> Enum.sum(), by_group: groups}
  end
end
