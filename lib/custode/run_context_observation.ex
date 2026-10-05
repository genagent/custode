defmodule Custode.RunContextObservation do
  @moduledoc "First accepted engine session observation for one retained adapter context; never context receipt or use."
  alias Custode.{Repo, RunContextReceipts}
  alias RunContextReceipts.Row

  @strings ~w(agent_id agent_generation agent_turn_id arc_id config_revision)
  @providers %{
    oban_claude:
      {"claude", "ObanClaude.Agent.Job", ObanClaude.Agent.Registry, ObanCodex.Agent.Registry,
       :system_init},
    oban_codex:
      {"codex", "ObanCodex.Agent.Job", ObanCodex.Agent.Registry, ObanClaude.Agent.Registry,
       :thread_started}
  }

  @doc false
  # This handler executes synchronously inside the registered engine instance,
  # after its PID/reference and active-attempt fences accept the native event.
  # Calling Agent.info here would call that same process and deadlock.
  def observe(provider, meta) when is_map(meta) do
    with {name, worker, registry, sibling, source} <- Map.get(@providers, provider),
         true <- valid_event?(meta, source),
         true <- owner?(registry, sibling, meta.agent_id) do
      Repo.transaction(
        fn -> attach!(provider, name, worker, registry, sibling, meta) end,
        mode: :immediate
      )
    else
      _unbound -> {:error, :unbound_native_observation}
    end
  end

  def observe(_provider, _meta), do: {:error, :unbound_native_observation}

  defp valid_event?(
         %{
           correlation_id: correlation,
           job_id: id,
           job_attempt: attempt,
           job_snoozed: snoozed,
           execution_state: :started,
           source: source
         } = meta,
         source
       )
       when is_integer(id) and id > 0 and is_integer(attempt) and attempt > 0 and
              is_integer(snoozed) and snoozed >= 0 do
    Enum.all?(@strings, fn key -> nonblank?(Map.get(meta, existing_atom(key))) end) and
      optional_identity?(correlation) and valid_handle?(meta[:session_id])
  end

  defp valid_event?(_meta, _source), do: false
  defp optional_identity?(nil), do: true
  defp optional_identity?(value), do: nonblank?(value)

  defp owner?(registry, sibling, id) do
    match?([{pid, _value}] when pid == self(), lookup(registry, id)) and
      lookup(sibling, id) == []
  end

  defp lookup(registry, id) do
    if Process.whereis(registry), do: Registry.lookup(registry, id), else: []
  end

  defp attach!(provider, name, worker, registry, sibling, meta) do
    job = Repo.get(Oban.Job, meta.job_id)
    row = context_row(provider, job)

    with true <- owner?(registry, sibling, meta.agent_id),
         %Row{} <- row,
         %Oban.Job{} <- job,
         true <- retained?(row),
         true <- exact_execution?(row, job, name, worker, meta) do
      persist_first!(row, meta)
    else
      _stale -> Repo.rollback(:unbound_native_observation)
    end
  end

  defp context_row(provider, %Oban.Job{} = job) do
    id = "rc-" <> digest({provider, job.id, job.attempt, job.meta["snoozed"]})
    Repo.get(Row, id)
  end

  defp context_row(_provider, _job), do: nil

  defp retained?(row) do
    row.record["payload_state"] == "retained" and is_binary(row.payload) and
      DateTime.compare(DateTime.utc_now(), DateTime.add(row.at, 7, :day)) == :lt
  end

  defp exact_execution?(row, job, provider, worker, meta) do
    job_contract?(job, worker, meta) and receipt_contract?(row, job, provider, meta) and
      row.record["arguments_sha256"] == digest(job.args) and
      row.record["job_metadata_sha256"] == digest(job.meta)
  end

  defp job_contract?(job, worker, meta) do
    job.worker == worker and job.state == "executing" and job.attempt == meta.job_attempt and
      (job.meta["snoozed"] || 0) == meta.job_snoozed
  end

  defp receipt_contract?(row, job, provider, meta) do
    execution = row.record["execution"]

    row.agent_id == meta.agent_id and execution["provider"] == provider and
      execution["job_id"] == job.id and execution["attempt"] == meta.job_attempt and
      execution["snoozed"] == meta.job_snoozed and
      Enum.all?(@strings ++ ["correlation_id"], fn key ->
        observed = Map.get(meta, existing_atom(key))
        job.meta[key] == observed and execution[key] == observed
      end)
  end

  defp persist_first!(row, meta) do
    fact = %{
      "provider_session_id" => meta.session_id,
      "source" => Atom.to_string(meta.source),
      "evidence" => "accepted_registered_engine_native_session_observation",
      "context_received" => "unknown",
      "model_used" => "unknown"
    }

    case row.record["native_observation"] do
      nil ->
        fact = Map.put(fact, "observed_at", DateTime.to_iso8601(DateTime.utc_now()))

        row
        |> Ecto.Changeset.change(record: Map.put(row.record, "native_observation", fact))
        |> Repo.update!()
        |> Map.fetch!(:record)
        |> Map.fetch!("native_observation")

      existing ->
        if Map.drop(existing, ["observed_at"]) == fact,
          do: existing,
          else: Repo.rollback(:conflicting_native_observation)
    end
  end

  defp valid_handle?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and nonblank?(value)

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  # Fixed internal names only; never intern event or caller strings.
  defp existing_atom(key), do: String.to_existing_atom(key)

  defp digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp digest(value), do: value |> :erlang.term_to_binary([:deterministic]) |> digest()
end
