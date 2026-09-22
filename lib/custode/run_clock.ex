defmodule Custode.RunClock do
  @moduledoc """
  What is executing RIGHT NOW, and since when (#211's in-flight panel).

  Each provider emits its `[:run, :start]` event before a subprocess and
  `:stop`/`:exception` after. This owns a public ETS table
  mapping `agent_id => started_at`: a start writes it, a stop/exception
  clears it, so `running/0` is the live set of in-flight turns with their
  ages. Pure observability; the handlers are armored (a clock must never
  cost a turn) and the table survives handler processes because this
  GenServer owns it.
  """

  use GenServer

  require Logger

  @table :custode_run_clock
  @events [
    [:oban_claude, :run, :start],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception],
    [:oban_codex, :run, :start],
    [:oban_codex, :run, :stop],
    [:oban_codex, :run, :exception]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc false
  def attach do
    :telemetry.attach_many("custode-run-clock", @events, &__MODULE__.handle_event/4, nil)
  end

  @doc "Agents with a turn in flight: `%{agent_id => started_at}` (DateTimes)."
  def running do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    # the table may not exist yet in a bare test process; empty is honest
    ArgumentError -> %{}
  end

  @doc false
  def handle_event(
        [provider, :run, event],
        _measurements,
        %{job: %{meta: %{"custode_kind" => "gate_review"}}},
        _config
      )
      when provider in [:oban_claude, :oban_codex] and event in [:start, :stop, :exception],
      do: :ok

  def handle_event([provider, :run, :start], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    case agent_of(meta) do
      nil -> :ok
      agent -> :ets.insert(@table, {agent, DateTime.utc_now()})
    end

    :ok
  rescue
    exception ->
      Logger.error(
        "Custode.RunClock handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  def handle_event([provider, :run, _stop_or_exception], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    case agent_of(meta) do
      nil -> :ok
      agent -> :ets.delete(@table, agent)
    end

    :ok
  rescue
    exception ->
      Logger.error(
        "Custode.RunClock handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: nil
end
