defmodule Custode.Operator.Authority do
  @moduledoc "Transport-neutral authority checks for operator-facing actions."

  @type actor :: %{
          required(:kind) => :operator | :routine | :sub_agent,
          optional(:id) => String.t()
        }

  @doc "The bounded fleet-control bundle shared by the human and the caretaker."
  @spec fleet_control(actor()) :: :ok | {:error, String.t()}
  def fleet_control(%{kind: :operator}), do: :ok

  def fleet_control(%{kind: :routine, id: id}) do
    case Custode.AgentHandoff.authorization_routine(id) do
      {:ok, %{role: :caretaker}} -> :ok
      {:error, :handoff_pending} -> {:error, handoff_error(id)}
      _other -> {:error, "identity: fleet control requires the human operator or caretaker role"}
    end
  end

  def fleet_control(_actor),
    do: {:error, "identity: fleet control requires the human operator or caretaker role"}

  @doc "Actions that change operator state or the whole node remain human-only."
  @spec human(actor()) :: :ok | {:error, String.t()}
  def human(%{kind: :operator}), do: :ok
  def human(_actor), do: {:error, "identity: this action requires the human operator"}

  @doc "Roster/profile writes require a human or the caretaker's live roster approval."
  @spec roster_write(actor()) :: :ok | {:error, String.t()}
  def roster_write(%{kind: :operator}), do: :ok

  def roster_write(%{kind: :routine, id: id}) do
    with :ok <- caretaker(id),
         %{class: "roster"} <- Custode.Gates.active_grant(id) do
      :ok
    else
      {:error, _reason} = error ->
        error

      _no_roster_grant ->
        {:error,
         "approval: caretaker roster writes require an active human-approved roster continuation"}
    end
  end

  def roster_write(%{kind: :sub_agent}),
    do: {:error, "identity: temporary agents may not write the roster or profiles"}

  def roster_write(_actor),
    do: {:error, "identity: roster writes require the human operator or caretaker role"}

  defp caretaker(id) do
    case Custode.AgentHandoff.authorization_routine(id) do
      {:ok, %{role: :caretaker}} -> :ok
      {:error, :handoff_pending} -> {:error, handoff_error(id)}
      _other -> {:error, "identity: roster writes require the human operator or caretaker role"}
    end
  end

  defp handoff_error(id),
    do: "identity: routine #{id} is changing configuration; retry after its handoff completes"
end
