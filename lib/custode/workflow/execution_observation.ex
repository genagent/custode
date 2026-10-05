defmodule Custode.Workflow.ExecutionObservation do
  @moduledoc "Private runner requests and returns; never successful spawn, native conformance or settlement."
  import Ecto.Query, only: [from: 2]
  alias Custode.Repo
  alias Custode.Workflow.{ExecutionPolicy, ResultContract, Results, Run}

  @scope {__MODULE__, :selected_job}
  @version "custode.workflow_runner_observation.v1"
  @max_argv 256
  @max_request_bytes 1_048_576

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :string, autogenerate: false}
    schema "workflow_runner_observations" do
      field(:workflow_run, :string)
      field(:job_id, :integer)
      field(:job_attempt, :integer)
      field(:execution_generation, :string)
      field(:binding, :map)
      field(:request, :map)
      field(:request_sha256, :string)
      field(:requested_at, :utc_datetime_usec)
      field(:transport_return, :map)
      field(:returned_at, :utc_datetime_usec)
    end
  end

  @doc false
  def with_job(%Oban.Job{} = job, fun) when is_function(fun, 0) do
    if scope(), do: raise(ArgumentError, "nested workflow runner scope")
    Process.put(@scope, %{job: job, reference: make_ref()})

    try do
      fun.()
    after
      Process.delete(@scope)
    end
  end

  @doc false
  def scope, do: Process.get(@scope)

  @doc false
  def request(binary, argv, opts, timeout) do
    case scope() do
      %{job: job, reference: reference} ->
        Repo.transaction(fn -> request!(job, reference, binary, argv, opts, timeout) end,
          mode: :immediate
        )

      nil ->
        {:error, :unbound_runner_scope}
    end
  end

  defp request!(job, reference, binary, argv, opts, timeout) do
    unless current_execution?(job) and command_bound?(job, binary, argv, opts, timeout),
      do: Repo.rollback(:unbound_runner_execution)

    if length(argv) > @max_argv, do: Repo.rollback(:runner_request_too_large)

    request = command_request(binary, argv, opts, timeout)
    binding = execution_binding(job)

    if byte_size(Jason.encode!(%{request: request, binding: binding})) > @max_request_bytes,
      do: Repo.rollback(:runner_request_too_large)

    hash = Results.args_hash(request)

    existing =
      Repo.one(
        from(row in Row,
          where:
            row.job_id == ^job.id and row.job_attempt == ^job.attempt and
              row.execution_generation == ^job.meta["execution_generation"]
        )
      )

    if existing do
      reason =
        if existing.request_sha256 == hash,
          do: :runner_already_requested,
          else: :conflicting_runner_request

      Repo.rollback(reason)
    end

    row =
      Repo.insert!(%Row{
        id: "wo-" <> Ecto.UUID.generate(),
        workflow_run: job.meta["workflow_run"],
        job_id: job.id,
        job_attempt: job.attempt,
        execution_generation: job.meta["execution_generation"],
        binding: binding,
        request: request,
        request_sha256: hash,
        requested_at: DateTime.utc_now()
      })

    %{id: row.id, reference: reference, request_sha256: hash, binding: row.binding}
  end

  defp current_execution?(job) do
    stored = Repo.get(Oban.Job, job.id)
    run = Run.get(job.meta["workflow_run"])

    job.worker == "Custode.Workflow.NodeJob" and ExecutionPolicy.selected?(run) and
      ResultContract.launch_check(job) == :ok and
      match?(%Oban.Job{state: "executing", attempt: 1, max_attempts: 1}, stored) and
      stored.worker == job.worker and stored.attempt == job.attempt and
      stored.args == job.args and stored.meta == job.meta
  end

  defp command_bound?(job, binary, argv, opts, timeout) do
    is_binary(binary) and binary != "" and is_list(argv) and
      Enum.all?(argv, &is_binary/1) and Enum.take(argv, -2) == ["--", job.args["prompt"]] and
      timeout == job.args["timeout"] and Keyword.get(opts, :cd) == job.args["working_dir"] and
      Keyword.get(opts, :env, []) == [] and
      Enum.all?(Keyword.keys(opts), &(&1 in [:cd, :env, :stderr_to_stdout]))
  end

  defp command_request(binary, argv, opts, timeout) do
    %{
      "schema_version" => @version,
      "basis" => "delegation_requested_at_released_runner_boundary_not_successful_spawn",
      "binary" => binary,
      "argv" => argv,
      "argv_sha256" => Results.args_hash(argv),
      "command_options" => opts |> Keyword.delete(:env) |> Map.new() |> json(),
      "environment_overrides_sha256" => Results.args_hash(Keyword.get(opts, :env, [])),
      "inherited_environment" => "unattested",
      "timeout_ms" => timeout,
      "runner" => "ClaudeWrapper.Runner.Forcola",
      "packages" =>
        Map.new([:claude_wrapper, :forcola], fn package ->
          {Atom.to_string(package), to_string(Application.spec(package, :vsn))}
        end),
      "native_conformance" => "unverified",
      "physical_settlement" => "unattested"
    }
  end

  defp execution_binding(job) do
    %{
      "workflow_run" => job.meta["workflow_run"],
      "job_id" => job.id,
      "job_attempt" => job.attempt,
      "execution_generation" => job.meta["execution_generation"],
      "arguments_sha256" => Results.args_hash(job.args),
      "metadata_sha256" => Results.args_hash(job.meta),
      "result_contract_sha256" => Results.args_hash(job.meta["result_contract"])
    }
  end

  @doc false
  # A late return belongs to its captured invocation, even if the run has failed
  # meanwhile. It records history only and never changes current run or results.
  def returned(token, outcome) do
    result = Repo.transaction(fn -> returned!(token, outcome) end, mode: :immediate)

    case result do
      {:ok, _record} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp returned!(token, outcome) do
    row = Repo.get(Row, token.id)

    with %{job: job, reference: reference} <- scope(),
         true <- reference == token.reference,
         %Row{} <- row,
         true <- row.binding == token.binding and row.binding == execution_binding(job),
         true <-
           row.request_sha256 == token.request_sha256 and
             row.request_sha256 == Results.args_hash(row.request) do
      first_return!(row, transport_return(outcome))
    else
      _unbound -> Repo.rollback(:unbound_transport_return)
    end
  end

  defp first_return!(%Row{transport_return: nil} = row, record) do
    row
    |> Ecto.Changeset.change(transport_return: record, returned_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp first_return!(%Row{transport_return: record} = row, record), do: row
  defp first_return!(_row, _record), do: Repo.rollback(:conflicting_transport_return)

  defp transport_return({:ok, {stdout, code}}) when is_binary(stdout) and is_integer(code) do
    %{
      "kind" => "exit",
      "exit_code" => code,
      "output_sha256" => Results.args_hash(stdout),
      "output_bytes" => byte_size(stdout),
      "physical_settlement" => "unattested"
    }
  end

  defp transport_return({:error, :timeout}),
    do: %{
      "kind" => "timeout",
      "detailed_timeout_result" => "unavailable",
      "physical_settlement" => "unattested"
    }

  defp transport_return({:error, {:signal, signal}}),
    do: %{
      "kind" => "signal",
      "signal" => if(is_integer(signal), do: signal, else: "unavailable"),
      "physical_settlement" => "unattested"
    }

  defp transport_return(outcome),
    do: %{
      "kind" => "error",
      "reason_sha256" => Results.args_hash(outcome),
      "physical_settlement" => "unattested"
    }

  @doc "Bounded sanitized observations; no command arguments, paths, environment or output values."
  def summary(run_id) do
    rows =
      Repo.all(
        from(row in Row,
          where: row.workflow_run == ^run_id,
          order_by: [asc: row.requested_at, asc: row.id],
          limit: 101,
          select: [
            :job_id,
            :job_attempt,
            :execution_generation,
            :request_sha256,
            :requested_at,
            :transport_return,
            :returned_at
          ]
        )
      )

    inventory = Enum.take(rows, 100)

    %{
      basis: "retained_delegation_requests_and_transport_returns_not_spawn_or_settlement",
      delegation_requests: length(inventory),
      transport_returns: Enum.count(inventory, &(not is_nil(&1.transport_return))),
      unknown_returns: Enum.count(inventory, &is_nil(&1.transport_return)),
      truncated: length(rows) > 100,
      physical_settlement: "unattested",
      observations:
        Enum.map(inventory, fn row ->
          %{
            job_id: row.job_id,
            job_attempt: row.job_attempt,
            execution_generation: row.execution_generation,
            request_sha256: row.request_sha256,
            requested_at: DateTime.to_iso8601(row.requested_at),
            transport_return: return_summary(row.transport_return),
            returned_at: if(row.returned_at, do: DateTime.to_iso8601(row.returned_at), else: nil)
          }
        end)
    }
  end

  defp return_summary(nil), do: nil

  defp return_summary(%{"kind" => kind} = record) when kind in ~w(exit timeout signal error) do
    code = record["exit_code"]

    %{
      "kind" => kind,
      "exit_code" => if(is_integer(code) and code in 0..255, do: code, else: nil),
      "physical_settlement" => "unattested"
    }
  end

  defp return_summary(_record),
    do: %{"kind" => "unavailable", "physical_settlement" => "unattested"}

  def delete_run(run_id),
    do: Repo.delete_all(from(row in Row, where: row.workflow_run == ^run_id)) |> elem(0)

  defp json(value), do: Jason.decode!(Jason.encode!(value))
end
