defmodule Custode.Workflow.ResultContract do
  @moduledoc "Frozen host callback validation; never native execution or replay authority."
  alias Custode.Repo
  alias Custode.Workflow.{NodeJob, Results, Run}
  alias Snodo.Schema.Validator.Basic

  @version "custode.workflow_result_contract.v1"
  @identity ~w(workflow_run workflow stage node_name args_hash execution_generation)
  @sizes ~w(minItems maxItems minProperties maxProperties)
  @bounds ~w(minimum maximum exclusiveMinimum exclusiveMaximum)
  @json_types ~w(object array string boolean number integer null)
  @annotations ~w(title description default examples $schema $id $comment deprecated readOnly writeOnly)

  def version, do: @version
  def required?(run), do: Map.has_key?(run.context, "result_contract_version")

  def capture(run, args, meta) do
    %{
      "version" => @version,
      "identity" => Map.take(meta, @identity),
      "definition_sha256" => Results.args_hash(run.definition_snapshot),
      "launch_args_sha256" => Results.args_hash(args),
      "pinned_policy_sha256" => policy_revision(),
      "schema" => decode_schema(args["json_schema"])
    }
  end

  def check(run, job) do
    cond do
      not required?(run) ->
        :ok

      run.context["result_contract_version"] != @version ->
        {:error, :unknown_result_contract}

      job.meta["result_contract"] != capture(run, job.args, job.meta) or
          not frozen_inputs?(run, job) ->
        {:error, :result_contract_changed_or_missing}

      true ->
        :ok
    end
  end

  defp frozen_inputs?(run, job) do
    with %{"stages" => stages} = definition when is_list(stages) <- run.definition_snapshot,
         %{"nodes" => nodes} = stage when is_list(nodes) <-
           Enum.find(stages, &(is_map(&1) and &1["name"] == job.meta["stage"])),
         node when is_map(node) <- Enum.find(nodes, &matches_node?(&1, stage, job)) do
      schema = decode_schema(job.args["json_schema"])

      inputs = %{
        prompt: job.args["prompt"],
        schema: schema,
        model: effective_setting("model", node, stage, definition),
        effort: effective_setting("effort", node, stage, definition)
      }

      schema == node["schema"] and job.args["model"] == inputs.model and
        job.args["effort"] == inputs.effort and job.meta["args_hash"] == Results.args_hash(inputs)
    else
      _missing -> false
    end
  end

  defp effective_setting(key, node, stage, definition),
    do: node[key] || stage[key] || definition[key]

  defp matches_node?(%{"name" => name}, stage, job) when is_binary(name) do
    actual = job.meta["node_name"]
    prefix = name <> "_"

    if stage["per_item"] == true do
      is_binary(actual) and String.starts_with?(actual, prefix) and
        Regex.match?(~r/^[1-9][0-9]*$/, String.replace_prefix(actual, prefix, ""))
    else
      actual == name
    end
  end

  defp matches_node?(_node, _stage, _job), do: false

  def launch_check(%{meta: %{"workflow_run" => id}} = job) do
    case Run.get(id) do
      nil -> if(job.meta["result_contract"], do: {:error, :unknown_run}, else: :ok)
      run -> check_launch(run, job)
    end
  end

  def launch_check(_job), do: :ok

  defp check_launch(run, job) do
    if required?(run) do
      with :ok <- check(run, job),
           true <-
             supported_schema?(job.meta["result_contract"]["schema"]) ||
               {:error, :unsupported_result_schema},
           true <- job.max_attempts == 1 and job.attempt in [0, 1],
           true <- run.status == "running" and run.stage == job.meta["stage"],
           true <- run.execution_generation == job.meta["execution_generation"],
           true <- is_nil(Results.fetch(run.run_id, job.meta["node_name"], job.meta["args_hash"])),
           true <- is_integer(job.id),
           %{} = stored <- Repo.get(Oban.Job, job.id),
           true <- stored.args == job.args and stored.meta == job.meta do
        :ok
      else
        {:error, _} = error -> error
        _unbound -> {:error, :workflow_execution_not_current}
      end
    else
      :ok
    end
  end

  def validate(run, job, payload, meta) do
    contract = job.meta["result_contract"]

    receipt = %{
      "version" => @version,
      "contract" => contract,
      "contract_sha256" => Results.args_hash(contract),
      "job_id" => job.id,
      "callback_attempt" => meta["callback_attempt"],
      "attempt_binding" =>
        if(is_nil(meta["callback_attempt"]), do: "unavailable", else: "recorded_job_attempt"),
      "payload_sha256" => Results.args_hash(payload),
      "basis" => "host_callback_schema_validation_not_native_execution",
      "native_identity" => "unknown",
      "physical_settlement" => "unattested"
    }

    cond do
      Map.has_key?(meta, "callback_attempt") and meta["callback_attempt"] != job.attempt ->
        {:error, Map.put(receipt, "state", "callback_attempt_unbound")}

      check(run, job) != :ok ->
        {:error, Map.put(receipt, "state", "contract_unbound")}

      not supported_schema?(contract["schema"]) ->
        {:error, Map.put(receipt, "state", "schema_validation_unavailable")}

      not is_map(payload) or Basic.validate(payload, contract["schema"]) != :ok ->
        {:error, Map.put(receipt, "state", "invalid_structured_output")}

      true ->
        {:ok, Map.put(receipt, "state", "schema_validated")}
    end
  end

  @doc "Check retained data and frozen definition bindings without granting replay authority."
  def receipt_state(result, run) do
    receipt = result[:validation]

    with %{"state" => "schema_validated", "version" => @version, "contract" => contract} <-
           receipt,
         true <- is_map(contract) and is_map(contract["identity"]),
         true <- receipt["contract_sha256"] == Results.args_hash(contract),
         true <- receipt["payload_sha256"] == Results.args_hash(result.result),
         true <- contract["definition_sha256"] == Results.args_hash(run.definition_snapshot),
         true <- contract["identity"]["execution_generation"] == run.execution_generation,
         true <- contract["identity"]["workflow_run"] == result.workflow_run,
         true <- contract["identity"]["workflow"] == result.workflow,
         true <- contract["identity"]["stage"] == result.stage,
         true <- contract["identity"]["node_name"] == result.node_name,
         true <- contract["identity"]["args_hash"] == result.args_hash,
         true <- supported_schema?(contract["schema"]),
         :ok <- Basic.validate(result.result, contract["schema"]) do
      "schema_validated"
    else
      _unbound -> "legacy_or_unbound"
    end
  end

  defp policy_revision do
    Results.args_hash(%{
      pinned_args: NodeJob.pinned_args(),
      packages:
        Map.new([:oban_claude, :claude_wrapper, :snodo], &{&1, Application.spec(&1, :vsn)})
    })
  end

  defp decode_schema(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, schema} -> schema
      _invalid -> nil
    end
  end

  defp decode_schema(_text), do: nil

  defp supported_schema?(schema) when is_map(schema) do
    Enum.all?(schema, fn
      {"properties", fields} when is_map(fields) ->
        Enum.all?(fields, fn {key, value} -> is_binary(key) and nested_schema?(value) end)

      {key, value} when key in ~w(items additionalProperties) ->
        nested_schema?(value)

      {"properties", _malformed} ->
        false

      {"type", value} ->
        List.wrap(value) != [] and Enum.all?(List.wrap(value), &(&1 in @json_types))

      {"required", value} ->
        is_list(value) and Enum.all?(value, &is_binary/1) and
          length(value) == length(Enum.uniq(value))

      {"enum", value} ->
        is_list(value) and value != []

      {"const", _value} ->
        true

      {"uniqueItems", value} ->
        is_boolean(value)

      {key, value} when key in @sizes ->
        is_integer(value) and value >= 0

      {key, value} when key in @bounds ->
        is_number(value)

      {key, _value} ->
        key in @annotations
    end)
  end

  defp supported_schema?(_schema), do: false
  defp nested_schema?(value) when is_boolean(value), do: true
  defp nested_schema?(value), do: supported_schema?(value)
end
