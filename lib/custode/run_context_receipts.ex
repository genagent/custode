defmodule Custode.RunContextReceipts do
  @moduledoc "Immutable inline context observed at adapter entry; native receipt and use remain unknown."
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Custode.Repo

  @events [
    [:oban_claude, :run, :start],
    [:oban_codex, :run, :start],
    [:oban_claude, :agent, :session_observed],
    [:oban_codex, :agent, :session_observed]
  ]
  @layers ~w(prompt system_prompt append_system_prompt developer_instructions)
  @identity ~w(agent_id agent_generation agent_turn_id arc_id config_revision)
  @payload_limit 131_072

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:receipt_id, :string, autogenerate: false}
    schema "run_context_receipts" do
      field(:agent_id, :string)
      field(:record, :map)
      field(:payload, :string)
      field(:at, :utc_datetime_usec)
    end
  end

  def attach do
    :telemetry.attach_many(
      "custode-run-context-receipts",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([provider, :run, :start], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    case capture(provider, meta) do
      {:error, reason} -> Logger.warning("Run context capture unavailable: #{inspect(reason)}")
      _other -> :ok
    end
  rescue
    error -> Logger.warning("Run context capture unavailable: #{inspect(error.__struct__)}")
  end

  def handle_event([provider, :agent, :session_observed], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    Custode.RunContextObservation.observe(provider, meta)
  rescue
    error -> Logger.warning("Run context observation unavailable: #{inspect(error.__struct__)}")
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc "Capture actual adapter arguments only when they match the exact durable executing job."
  def capture(provider, %{args: args, job: %{id: id, attempt: attempt, meta: meta}})
      when provider in [:oban_claude, :oban_codex] and is_map(args) and is_map(meta) and
             is_integer(id) and id > 0 and is_integer(attempt) and attempt > 0 do
    with %Oban.Job{} = job <- Repo.get(Oban.Job, id),
         true <- exact_job?(job, provider, args, attempt, meta),
         true <- is_binary(args["prompt"]) do
      persist(provider, job, args, meta)
    else
      _unbound -> {:error, :unbound_adapter_execution}
    end
  end

  def capture(_provider, _meta), do: {:error, :unbound_adapter_execution}

  @doc "Operator-only reads keep inline instructions private from other agents."
  def read(%{kind: :operator, id: actor}, id) when is_binary(actor) and actor != "" do
    expire(from(row in Row, where: row.receipt_id == ^id))

    case Repo.get(Row, id) do
      nil -> {:error, "run_context_unavailable"}
      row -> {:ok, project(row)}
    end
  end

  def read(_actor, _id), do: {:error, "operator_required"}

  def list(%{kind: :operator, id: actor}, agent_id) when is_binary(actor) and actor != "" do
    expire(from(row in Row, where: row.agent_id == ^agent_id))

    records =
      Repo.all(
        from(row in Row,
          where: row.agent_id == ^agent_id,
          order_by: [desc: row.at, desc: row.receipt_id],
          limit: 100
        )
      )
      |> Enum.map(&(project(&1) |> Map.delete("exact_inline_layers")))

    {:ok, records}
  end

  def list(_actor, _agent_id), do: {:error, "operator_required"}

  @doc "Operator-only exact historical assignment link, independent of current jobs and list windows."
  def assignment_reference(%{kind: :operator, id: actor}, %{"execution" => execution} = binding)
      when is_binary(actor) and actor != "" and is_map(execution) do
    rows =
      execution
      |> assignment_receipt_ids()
      |> then(fn ids -> Repo.all(from(row in Row, where: row.receipt_id in ^ids)) end)
      |> Enum.filter(fn row ->
        row.agent_id == execution["agent_id"] and row.record["assignment_execution"] == binding and
          Map.take(row.record["execution"] || %{}, Map.keys(execution)) == execution
      end)

    agent = execution["agent_id"]

    case rows do
      [row] ->
        {:ok, receipt} = read(%{kind: :operator, id: actor}, row.receipt_id)

        %{
          "availability" => "captured_adapter_entry",
          "receipt_id" => row.receipt_id,
          "payload_state" => receipt["payload_state"],
          "link" =>
            "/contexts/" <>
              URI.encode_www_form(agent) <> "?receipt=" <> URI.encode_www_form(row.receipt_id),
          "native_context_receipt_and_use" => "unknown"
        }

      _unavailable ->
        %{"availability" => "exact_assignment_context_unavailable"}
    end
  end

  def assignment_reference(%{kind: :operator}, _binding),
    do: %{"availability" => "exact_assignment_context_unavailable"}

  def assignment_reference(_actor, _binding), do: %{"availability" => "operator_required"}

  # First attempts historically hashed raw nil; the retained binding normalizes it to zero.
  # Only these primary keys are candidates, and full provenance must still match afterward.
  defp assignment_receipt_ids(%{
         "provider" => provider,
         "job_id" => job,
         "attempt" => attempt,
         "snoozed" => snoozed
       })
       when provider in ["claude", "codex"] and is_integer(job) and job > 0 and
              is_integer(attempt) and attempt > 0 and is_integer(snoozed) and snoozed >= 0 do
    provider = if provider == "claude", do: :oban_claude, else: :oban_codex
    candidates = if snoozed == 0, do: [nil, 0], else: [snoozed]
    Enum.map(candidates, &("rc-" <> digest({provider, job, attempt, &1})))
  end

  defp assignment_receipt_ids(_invalid), do: []

  defp exact_job?(job, provider, args, attempt, meta) do
    worker = if provider == :oban_claude, do: "ObanClaude.Agent.Job", else: "ObanCodex.Agent.Job"

    job.worker == worker and job.state == "executing" and job.attempt == attempt and
      job.args == args and
      same_identity?(job.meta, meta) and job.meta["correlation_id"] == meta["correlation_id"] and
      job.meta["snoozed"] == meta["snoozed"]
  end

  defp same_identity?(stored, observed) do
    Enum.all?(@identity, fn key ->
      is_binary(observed[key]) and observed[key] != "" and stored[key] == observed[key]
    end)
  end

  defp persist(provider, job, args, meta) do
    id = "rc-" <> digest({provider, job.id, job.attempt, meta["snoozed"]})
    inline = inline_arguments(args)
    layers = Map.take(inline, @layers) |> Map.reject(fn {_key, value} -> not is_binary(value) end)
    payload = Jason.encode!(layers)
    now = DateTime.utc_now()

    assignment = Custode.SubjectAssignments.adapter_binding(job)

    record = %{
      "receipt_id" => id,
      "agent_id" => meta["agent_id"],
      "state" => "adapter_entered",
      "execution" =>
        Map.merge(Map.take(meta, @identity ++ ["correlation_id"]), %{
          "provider" => if(provider == :oban_claude, do: "claude", else: "codex"),
          "job_id" => job.id,
          "attempt" => job.attempt,
          "snoozed" => meta["snoozed"] || 0,
          "requested_model" => args["model"],
          "requested_effort" => args["effort"] || override_value(args, "model_reasoning_effort"),
          "config_overrides_observed" => "digest_only_may_contain_credentials",
          "requested_session_id" => args["resume"] || args["session_id"],
          "native_session_observation" => "unknown_on_adapter_entry"
        }),
      "layers" => Enum.map(@layers, &layer(&1, inline)),
      "file_layers" =>
        Enum.map(~w(system_prompt_file append_system_prompt_file), fn name ->
          %{"name" => name, "requested_path" => args[name], "content_state" => "not_observed"}
        end),
      "document_tool_binding" =>
        if(assignment,
          do: "host_assignment_credential_available_at_adapter_entry",
          else: "unknown_without_turn_scoped_tool_credential"
        ),
      "assignment_execution" => assignment,
      "native_hidden_context" => "unknown",
      "provider_received" => "unknown",
      "model_used" => "unknown",
      "tokens" => nil,
      "payload_bytes" => byte_size(payload),
      "payload_sha256" => digest(payload),
      "arguments_sha256" => digest(args),
      "job_metadata_sha256" => digest(job.meta),
      "execution_identity_sha256" =>
        digest(Map.take(meta, @identity ++ ["correlation_id", "snoozed"])),
      "payload_budget" => @payload_limit,
      "retention" =>
        "seven_day_logical_expiry_lazy_cleanup_on_read_list_capture_newest_100_per_agent",
      "recorded_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> DateTime.add(7, :day) |> DateTime.to_iso8601(),
      "payload_state" =>
        if(byte_size(payload) <= @payload_limit, do: "retained", else: "over_budget")
    }

    Repo.transaction(
      fn -> insert_or_replay(id, meta["agent_id"], record, payload, now) end,
      mode: :immediate
    )
  end

  defp insert_or_replay(id, agent, record, payload, now) do
    case Repo.get(Row, id) do
      nil ->
        row =
          Repo.insert!(%Row{
            receipt_id: id,
            agent_id: agent,
            record: record,
            payload: if(record["payload_state"] == "retained", do: payload),
            at: now
          })

        prune(agent, now)
        project(row)

      %{record: old} = row ->
        if old["arguments_sha256"] == record["arguments_sha256"] and
             old["execution_identity_sha256"] == record["execution_identity_sha256"],
           do: project(row),
           else: Repo.rollback(:execution_context_conflict)
    end
  end

  defp inline_arguments(args) do
    case override_value(args, "developer_instructions") do
      nil -> args
      text -> Map.put(args, "developer_instructions", text)
    end
  end

  # Custode serializes these two exact TOML override values as JSON strings.
  # Never retain arbitrary overrides: MCP authorization headers contain tokens.
  defp override_value(args, name) do
    args
    |> Map.get("config_overrides", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, name <> "=")))
    |> List.last()
    |> decode_override(name)
  end

  defp decode_override(nil, _name), do: nil

  defp decode_override(value, name) do
    case Jason.decode(String.replace_prefix(value, name <> "=", "")) do
      {:ok, text} when is_binary(text) -> text
      _unsupported -> nil
    end
  end

  defp layer(name, args) do
    case args[name] do
      text when is_binary(text) ->
        %{
          "name" => name,
          "state" => "inline_argument",
          "bytes" => byte_size(text),
          "sha256" => digest(text)
        }

      nil ->
        %{"name" => name, "state" => "not_supplied_inline"}

      _other ->
        %{"name" => name, "state" => "unsupported_argument_shape"}
    end
  end

  defp project(row) do
    expired = DateTime.compare(DateTime.utc_now(), row.at |> DateTime.add(7, :day)) != :lt

    state =
      cond do
        expired -> "expired"
        row.record["payload_state"] == "over_budget" -> "over_budget"
        is_nil(row.payload) -> "retired"
        true -> "retained"
      end

    Map.merge(row.record, %{
      "payload_state" => state,
      "exact_inline_layers" => if(state == "retained", do: Jason.decode!(row.payload), else: nil),
      "document_retrievals" =>
        Custode.SubjectAssignments.retrievals(row.record["assignment_execution"])
    })
  end

  defp expire(query) do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    Repo.update_all(from(row in query, where: row.at <= ^cutoff and not is_nil(row.payload)),
      set: [payload: nil]
    )
  end

  defp prune(agent, now) do
    keep =
      Repo.all(
        from(row in Row,
          where: row.agent_id == ^agent,
          order_by: [desc: row.at, desc: row.receipt_id],
          limit: 100,
          select: row.receipt_id
        )
      )

    cutoff = DateTime.add(now, -7, :day)

    Repo.update_all(
      from(row in Row,
        where: row.agent_id == ^agent and (row.receipt_id not in ^keep or row.at < ^cutoff)
      ),
      set: [payload: nil]
    )
  end

  defp digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp digest(value), do: value |> :erlang.term_to_binary([:deterministic]) |> digest()
end
