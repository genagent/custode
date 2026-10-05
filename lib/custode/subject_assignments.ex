defmodule Custode.SubjectAssignments do
  @moduledoc "Operator admissions grant exact documents only through one host-bound helper turn."
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    AgentHandoff,
    HelperRecords,
    OperatorMessage,
    Repo,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  alias Custode.MCP.Identity
  alias Custode.SubjectAssignmentLaunch
  alias Snodo.Schema.Validator.Basic

  defmodule Assignment do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:assignment_id, :string, autogenerate: false}
    schema "subject_assignments" do
      field(:helper_id, :string)
      field(:root_id, :string)
      field(:fingerprint, :string)
      field(:status, :string)
      field(:record, :map)
      field(:expires_at, :utc_datetime_usec)
      field(:at, :utc_datetime_usec)
    end
  end

  defmodule Launch do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:launch_id, :string, autogenerate: false}
    schema "subject_assignment_launches" do
      field(:assignment_id, :string)
      field(:job_id, :integer)
      field(:record, :map)
      field(:config_path, :string)
      # Credential terminal fence only; never evidence of physical process settlement.
      field(:settled, :boolean, default: false)
      field(:at, :utc_datetime_usec)
    end
  end

  @identity ~w(agent_id agent_generation agent_turn_id arc_id config_revision correlation_id)
  @limit 1000

  @doc false
  def attach do
    :telemetry.attach_many(
      "custode-subject-assignment-terminal",
      [[:oban_claude, :run, :stop], [:oban_claude, :run, :exception]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(_event, _measurements, %{job: %{id: id}}, _config) do
    for launch <- Repo.all(from(row in Launch, where: row.job_id == ^id)) do
      Identity.revoke_assignment(launch.launch_id)
      launch |> Ecto.Changeset.change(settled: true) |> Repo.update!()
      SubjectAssignmentLaunch.remove_config(launch)
    end

    :ok
  rescue
    _error -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  def invoke(%{kind: :operator, id: id} = actor, params) when is_binary(id) and id != "" do
    with :ok <- Basic.validate(params, input_schema()), do: operation(actor, params)
  end

  def invoke(_actor, _params), do: {:error, "operator_assignment_admission_required"}

  defp operation(actor, %{"action" => "admit"} = params) do
    with true <-
           Enum.all?(
             ~w(assignment_id helper_id root_id expected_root_revision expected_helper_record_id read_paths destination expires_in_seconds),
             &Map.has_key?(params, &1)
           ),
         true <- Enum.all?(params["read_paths"], &SubjectDocuments.assignment_path?/1),
         true <- SubjectDocuments.assignment_path?(params["destination"]),
         {:ok, epoch} <- current_epoch(params["helper_id"]),
         true <- epoch["record_id"] == params["expected_helper_record_id"],
         definition when is_map(definition) <- SubjectDocuments.assignment_root(params["root_id"]),
         true <- SubjectDocuments.digest(definition) == params["expected_root_revision"],
         {:ok, binding} <- SubjectDocumentBridge.invoke(definition, %{"action" => "binding"}) do
      persist(actor, params, epoch, definition, binding)
    else
      _invalid -> {:error, "assignment_admission_unavailable"}
    end
  end

  defp operation(_actor, %{"action" => "read", "assignment_id" => id}) do
    case Repo.get(Assignment, id) do
      nil -> {:error, "assignment_unavailable"}
      row -> {:ok, project(row)}
    end
  end

  defp operation(_actor, %{"action" => "revoke", "assignment_id" => id}) do
    with {:ok, value} <- Repo.transaction(fn -> revoke!(id) end, mode: :immediate) do
      cleanup()
      {:ok, value}
    end
  end

  defp operation(_actor, _params), do: {:error, "missing_assignment_arguments"}

  defp persist(actor, params, epoch, definition, binding) do
    fingerprint = SubjectDocuments.digest({actor, params})

    Repo.transaction(
      fn ->
        case Repo.get(Assignment, params["assignment_id"]) do
          %Assignment{fingerprint: ^fingerprint} = row -> project(row)
          %Assignment{} -> Repo.rollback("idempotency_conflict")
          nil -> insert_assignment!(actor, params, epoch, definition, binding, fingerprint)
        end
      end,
      mode: :immediate
    )
  end

  defp insert_assignment!(actor, params, epoch, definition, binding, fingerprint) do
    if Repo.aggregate(Assignment, :count) >= @limit, do: Repo.rollback("assignment_record_limit")

    pending =
      Repo.exists?(
        from(row in Assignment,
          where:
            row.helper_id == ^params["helper_id"] and row.status == "admitted" and
              row.expires_at > ^DateTime.utc_now()
        )
      )

    if pending, do: Repo.rollback("helper_has_pending_assignment")

    if current_epoch(params["helper_id"], false) != {:ok, epoch},
      do: Repo.rollback("helper_epoch_changed")

    if SubjectDocuments.assignment_root(definition.id) != definition,
      do: Repo.rollback("root_configuration_changed")

    now = DateTime.utc_now()
    expires = DateTime.add(now, params["expires_in_seconds"], :second)

    record = %{
      "assignment_id" => params["assignment_id"],
      "admitted_by" => actor.id,
      "helper_epoch" => epoch,
      "parent" => epoch["parent"],
      "root_revision" => SubjectDocuments.digest(definition),
      "grant_revision" =>
        SubjectDocuments.digest(
          {epoch, definition, params["read_paths"], params["destination"], expires}
        ),
      "root_binding" => binding,
      "read_paths" => Enum.uniq(params["read_paths"]),
      "destination" => params["destination"],
      "expires_at" => DateTime.to_iso8601(expires),
      "launch_id" => nil,
      "parent_execution_binding" => "unknown_parent_identity_is_not_turn_attribution",
      "native_model_use" => "unknown"
    }

    %Assignment{
      assignment_id: params["assignment_id"],
      helper_id: params["helper_id"],
      root_id: definition.id,
      fingerprint: fingerprint,
      status: "admitted",
      record: record,
      expires_at: expires,
      at: now
    }
    |> Repo.insert!()
    |> project()
  end

  defp revoke!(id) do
    case Repo.get(Assignment, id) do
      nil -> Repo.rollback("assignment_unavailable")
      row -> row |> Ecto.Changeset.change(status: "revoked") |> Repo.update!() |> project()
    end
  end

  @doc "Called only by the host enqueue closure; never by a model-supplied tool argument."
  def pending(helper_id) do
    Repo.one(
      from(row in Assignment,
        where:
          row.helper_id == ^helper_id and row.status == "admitted" and
            row.expires_at > ^DateTime.utc_now(),
        limit: 1
      )
    )
  end

  @doc false
  def bind!(%Assignment{} = captured, args, meta, config_path, launch_id, job) do
    row = Repo.get!(Assignment, captured.assignment_id)

    with true <- row.status == "admitted",
         :ok <- current_assignment(row, false),
         true <- exact_meta?(meta, row.helper_id),
         %OperatorMessage{} = message <- delivery(meta, args, row.record["parent"]),
         true <- is_integer(job.id) and job.id > 0 and not job.conflict?,
         true <-
           job.worker == "ObanClaude.Agent.Job" and job.args == args and job.meta == meta and
             job.max_attempts == 1 do
      record = %{
        "execution" =>
          Map.merge(Map.take(meta, @identity), %{
            "provider" => "claude",
            "job_id" => job.id,
            "attempt" => 1,
            "snoozed" => 0
          }),
        "arguments_sha256" => SubjectDocuments.digest(args),
        "meta_sha256" => SubjectDocuments.digest(meta),
        "admission_message_id" => message.message_id,
        "helper_epoch" => row.record["helper_epoch"],
        "root_revision" => row.record["root_revision"],
        "grant_revision" => row.record["grant_revision"],
        "execution_binding" => "host_launch_credential_exact_job_not_model_use"
      }

      Repo.insert!(%Launch{
        launch_id: launch_id,
        assignment_id: row.assignment_id,
        job_id: job.id,
        record: record,
        config_path: config_path,
        at: DateTime.utc_now()
      })

      row
      |> Ecto.Changeset.change(
        status: "bound",
        record: Map.put(row.record, "launch_id", launch_id)
      )
      |> Repo.update!()

      job
    else
      _unbound -> Repo.rollback("assignment_launch_unbound")
    end
  end

  defp delivery(meta, args, parent) do
    Repo.one(
      from(message in OperatorMessage,
        where:
          message.provider_correlation_id == ^meta["correlation_id"] and
            message.target_agent_id == ^meta["agent_id"] and message.prompt == ^args["prompt"] and
            (message.caller_kind == "operator" or
               (message.caller_kind == "routine" and message.caller_id == ^parent)) and
            message.status not in ["failed", "refused"],
        order_by: [desc: message.inserted_at],
        limit: 1
      )
    )
  end

  defp exact_meta?(meta, helper_id),
    do:
      meta["agent_id"] == helper_id and
        Enum.all?(@identity, &(is_binary(meta[&1]) and meta[&1] != ""))

  @doc "Check the live persisted job and current assignment, never infer a turn from an agent snapshot."
  def authorize(actor) do
    case resolve(actor) do
      {:ok, _row, _launch} -> :ok
      _refused -> {:error, "assignment_execution_unavailable"}
    end
  end

  def grant(actor, definition) do
    with {:ok, row, _launch} <- resolve(actor),
         true <-
           row.root_id == definition.id and
             row.record["root_revision"] == SubjectDocuments.digest(definition) do
      %{
        read_paths: row.record["read_paths"],
        create_paths: [row.record["destination"]],
        propose_paths: [],
        proposal_destinations: []
      }
    else
      _refused -> nil
    end
  end

  def producer(actor) do
    %{
      "identity" => json(actor),
      "assignment_execution" => receipt_binding(actor),
      "native_session_observation" => "unknown",
      "model_used" => "unknown"
    }
  end

  def receipt_binding(%{subject_launch_id: _id} = actor) do
    case resolve(actor) do
      {:ok, row, launch} ->
        launch.record
        |> Map.drop(["arguments_sha256", "meta_sha256"])
        |> Map.merge(%{
          "assignment_id" => row.assignment_id,
          "launch_id" => launch.launch_id,
          "root_id" => row.root_id,
          "parent" => row.record["parent"]
        })

      _refused ->
        nil
    end
  end

  def receipt_binding(_actor), do: nil

  defp resolve(%{kind: :sub_agent, id: helper_id, subject_launch_id: id}) do
    with %Launch{settled: false} = launch <- Repo.get(Launch, id),
         %Assignment{helper_id: ^helper_id, status: "bound"} = row <-
           Repo.get(Assignment, launch.assignment_id),
         true <- row.record["launch_id"] == id,
         :ok <- current_assignment(row),
         %Oban.Job{} = job <- Repo.get(Oban.Job, launch.job_id),
         true <- live_job?(job, launch) do
      {:ok, row, launch}
    else
      _unavailable -> {:error, "assignment_execution_unavailable"}
    end
  end

  defp resolve(_actor), do: {:error, "assignment_execution_unavailable"}

  defp live_job?(job, launch) do
    job.worker == "ObanClaude.Agent.Job" and job.state == "executing" and job.attempt == 1 and
      job.max_attempts == 1 and
      (job.meta["snoozed"] || 0) == 0 and
      launch.record["arguments_sha256"] == SubjectDocuments.digest(job.args) and
      launch.record["meta_sha256"] == SubjectDocuments.digest(job.meta)
  end

  @doc false
  # The coordinator may be synchronously waiting on this helper's enqueue.
  # Invocation rechecks current parent authorization before granting any rights.
  def admission_current?(row), do: current_assignment(row, false)

  defp current_assignment(row, authorize_parent \\ true) do
    definition = SubjectDocuments.assignment_root(row.root_id)

    with true <- DateTime.compare(row.expires_at, DateTime.utc_now()) == :gt,
         {:ok, epoch} <- current_epoch(row.helper_id, authorize_parent),
         true <- epoch == row.record["helper_epoch"],
         true <-
           is_map(definition) and
             SubjectDocuments.digest(definition) == row.record["root_revision"] do
      :ok
    else
      _stale -> {:error, "assignment_stale"}
    end
  end

  defp current_epoch(helper_id, authorize_parent \\ true) do
    with {:ok, %{helper_epoch: epoch, parent: parent}} when not is_nil(epoch) <-
           HelperRecords.publication_reference(helper_id),
         :ok <- parent_current(parent, authorize_parent) do
      {:ok, Map.put(json(epoch), "parent", parent)}
    else
      _unavailable -> {:error, "current_helper_epoch_unavailable"}
    end
  end

  defp parent_current(_parent, false), do: :ok

  defp parent_current(parent, true) do
    case AgentHandoff.authorization_routine(parent) do
      {:ok, _routine} -> :ok
      _unavailable -> {:error, "current_parent_unavailable"}
    end
  end

  @doc "A host assignment credential available at adapter entry is distinct from a document delivery."
  def adapter_binding(%Oban.Job{id: job_id}) do
    case Repo.get_by(Launch, job_id: job_id) do
      nil ->
        nil

      launch ->
        row = Repo.get(Assignment, launch.assignment_id)

        if row,
          do:
            receipt_binding(%{
              kind: :sub_agent,
              id: row.helper_id,
              subject_launch_id: launch.launch_id
            })
    end
  end

  @doc "Bounded references to historical document payloads for one exact host launch, never current files."
  def retrievals(%{"launch_id" => launch_id, "execution" => execution}) do
    actor_key = "sub_agent:" <> execution["agent_id"]

    encoded = Jason.encode!(execution)

    matching =
      Repo.all(
        from(row in Custode.ContextReceipts.Row,
          where: row.actor_key == ^actor_key,
          where:
            fragment("json_extract(?, '$.assignment_execution.launch_id')", row.record) ==
              ^launch_id,
          where:
            fragment(
              "NOT EXISTS (SELECT fullkey, type, atom FROM json_tree(json_extract(?, '$.assignment_execution.execution')) EXCEPT SELECT fullkey, type, atom FROM json_tree(?))",
              row.record,
              ^encoded
            ),
          where:
            fragment(
              "NOT EXISTS (SELECT fullkey, type, atom FROM json_tree(?) EXCEPT SELECT fullkey, type, atom FROM json_tree(json_extract(?, '$.assignment_execution.execution')))",
              ^encoded,
              row.record
            ),
          order_by: [desc: row.at, asc: row.receipt_id],
          limit: 21
        )
      )

    %{
      "source" => "retained_document_receipts_exact_host_launch_not_model_use",
      "has_more" => length(matching) > 20,
      "receipts" =>
        Enum.map(Enum.take(matching, 20), fn row ->
          %{
            "receipt_id" => row.receipt_id,
            "root_id" => row.root_id,
            "path" => row.path,
            "revision" => row.record["revision"],
            "state" => row.record["state"],
            "payload_sha256" => row.record["payload_sha256"],
            "payload_bytes" => row.record["bytes"],
            "model_received" => row.record["model_received"],
            "expires_at" => row.record["expires_at"]
          }
        end)
    }
  end

  def retrievals(_unbound),
    do: %{"source" => "assignment_launch_unavailable", "receipts" => [], "has_more" => false}

  @doc "Remove expired/revoked/terminal launch credentials and private config files; keep outputs and receipts."
  def cleanup do
    for launch <- Repo.all(Launch) do
      row = Repo.get(Assignment, launch.assignment_id)
      job = Repo.get(Oban.Job, launch.job_id)

      if launch.settled or is_nil(row) or row.status == "revoked" or
           DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt or
           is_nil(job) or job.state in ~w(completed cancelled discarded retryable) or
           job.attempt > 1 do
        Identity.revoke_assignment(launch.launch_id)
        SubjectAssignmentLaunch.remove_config(launch)
      end
    end

    :ok
  end

  defp project(row) do
    row.record
    |> Map.merge(%{
      "root_id" => row.root_id,
      "helper_id" => row.helper_id,
      "status" => row.status,
      "authority" => "inactive_until_host_bound_executing_turn",
      "writes" => "create_only_no_apply"
    })
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  @doc false
  def input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(admit read revoke)},
        "assignment_id" => text(160),
        "helper_id" => text(160),
        "root_id" => text(160),
        "destination" => text(200),
        "expected_root_revision" => text(64),
        "expected_helper_record_id" => %{"type" => "integer", "minimum" => 1},
        "read_paths" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 100,
          "items" => text(200)
        },
        "expires_in_seconds" => %{"type" => "integer", "minimum" => 60, "maximum" => 3600}
      }
    }
  end

  defp text(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
end
