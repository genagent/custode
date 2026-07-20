defmodule Custode do
  @moduledoc """
  The human console for the routines. Every function targets the first
  configured routine by default; pass a routine id as the last argument to
  target another.

      iex> Custode.peek()          # status + spend + pendings + recent history
      iex> Custode.note("call the dentist re: tuesday")
      iex> Custode.beat()          # fire a sweep now instead of waiting for cron
      iex> Custode.poke("re-file yesterday's entries under one heading")
      iex> Custode.approve()       # release whatever it is blocked on
      iex> Custode.pause(); Custode.resume()
  """

  alias Custode.Routine
  alias ObanClaude.Agent

  @doc "Lifecycle status, straight off the registry."
  def status(id \\ nil), do: Agent.status(fetch!(id).id)

  @doc "Drop a note in the routine's inbox; the next sweep files it."
  def note(text, id \\ nil) do
    routine = fetch!(id)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    path = Path.join([Path.expand(routine.workspace), "inbox", "note-#{stamp}.md"])
    File.write!(path, text <> "\n")
    {:ok, path}
  end

  @doc "Fire one sweep right now (an out-of-schedule tick through the same policy)."
  def beat(id \\ nil) do
    routine = fetch!(id)

    {:ok, job} =
      Oban.insert(ObanClaude.Agent.Tick.new(Routine.tick_args(routine), queue: :ticks))

    {:ok, job.id}
  end

  @doc "Fire-and-forget prompt to the agent (queued if it is mid-sweep)."
  def poke(prompt, id \\ nil), do: Agent.cast_prompt(fetch!(id).id, prompt)

  @doc "Prompt and block until the turn is enqueued (the answer path for ask_user)."
  def ask(prompt, id \\ nil), do: Agent.submit_prompt(fetch!(id).id, prompt)

  @doc "Approve whatever action the agent is blocked on."
  def approve(id \\ nil) do
    agent_id = fetch!(id).id

    case Agent.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id, description: description}}} ->
        IO.puts("approving: #{description}")
        Agent.approve_action(agent_id, action_id)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc "Reject whatever action the agent is blocked on."
  def reject(reason \\ "denied", id \\ nil) do
    agent_id = fetch!(id).id

    case Agent.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id}}} ->
        Agent.reject_action(agent_id, action_id, reason)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc "Emergency lockdown: no sweeps, no prompts, until resume/1."
  def pause(id \\ nil), do: Agent.emergency_pause(fetch!(id).id)

  @doc "Release a paused agent."
  def resume(id \\ nil), do: Agent.resume_agent(fetch!(id).id)

  @doc "Pretty-print the last `n` feed entries (see `Custode.Feed`)."
  def feed(n \\ 20) do
    case Custode.Feed.tail(n) do
      [] ->
        IO.puts("(no feed yet: #{Custode.Feed.path()})")

      entries ->
        for entry <- entries do
          time = entry["at"] |> String.slice(11, 8)
          detail = entry["summary"] || entry["action"] || entry["question"] || entry["kind"] || ""
          cost = if entry["cost_usd"], do: " ($#{entry["cost_usd"]})", else: ""
          IO.puts("#{time} [#{entry["agent"]}] #{entry["event"]}#{cost} #{detail}")
        end
    end

    :ok
  end

  @doc "One readable snapshot: status, spend, pendings, and recent history."
  def peek(id \\ nil) do
    routine = fetch!(id)

    case Agent.status(routine.id) do
      {:ok, :offline} ->
        IO.puts("#{routine.id}: offline (next cron beat will start it; or Custode.beat())")

      {:ok, status} ->
        {:ok, info} = Agent.info(routine.id)
        {:ok, history} = Agent.history(routine.id)

        IO.puts("""
        #{routine.id}: #{inspect(status)}
          turns=#{info.turns} spend=$#{Float.round(info.cost_usd, 4)} session=#{info.session_id || "-"}
        """)

        for entry <- Enum.take(history, -8) do
          IO.puts("  " <> inspect(entry, printable_limit: 120))
        end
    end

    :ok
  end

  defp fetch!(nil), do: Routine.default()

  defp fetch!(id) do
    Routine.get(id) || raise ArgumentError, "no routine #{inspect(id)} configured"
  end
end
