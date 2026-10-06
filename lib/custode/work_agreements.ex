defmodule Custode.WorkAgreements do
  @moduledoc """
  Revisioned, attributed bookkeeping for work owned by a configured routine.

  Intent revisions and record sequences have separate meanings. Scope changes
  replace the intent at a new revision; checkpoints, submissions and human
  resolutions append records without changing that intent. Earlier evidence
  remains historical and never accepts a newer revision automatically.

  References are opaque attributed IDs or URLs, not verified evidence or read
  grants. Negative findings may have no output artifacts; a submission still
  requires criterion evidence and explicit verification limits. Only a human
  resolution accepts a submission, and that decision grants no execution or
  repository authority. These operations never dispatch, resume or cancel work.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentHandoff, Repo, Routine}
  alias Custode.WorkAgreements.Validation

  defmodule Agreement do
    @moduledoc false
    use Ecto.Schema

    schema "work_agreements" do
      field(:agreement_id, :string)
      field(:routine_id, :string)
      field(:current_revision, :integer, default: 1)
      field(:last_sequence, :integer, default: 0)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Record do
    @moduledoc false
    use Ecto.Schema

    schema "work_agreement_records" do
      field(:record_id, :string)
      field(:agreement_id, :string)
      field(:revision, :integer)
      field(:sequence, :integer)
      field(:kind, :string)
      field(:actor_kind, :string)
      field(:actor_id, :string)
      field(:actor_revision, :string)
      field(:request_id, :string)
      field(:fingerprint, :string)
      field(:payload, :map)
      field(:submission_id, :string)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  @doc "Create an agreement for a configured owner, without starting work."
  def create(actor, attrs) do
    with {:ok, context} <- context(actor),
         :ok <- manage_authority(context),
         {:ok, attrs} <- Validation.mutation(:create, attrs) do
      fingerprint = fingerprint(:create, nil, context, attrs)

      transaction(fn -> create_or_retry!(context, attrs, fingerprint) end)
    end
  end

  @doc "Replace current intent with a new revision using a compare-and-swap check."
  def revise(actor, agreement_id, attrs), do: mutate(:revise, actor, agreement_id, attrs)

  @doc "Record an owner's bounded progress assessment, separate from observed execution."
  def checkpoint(actor, agreement_id, attrs), do: mutate(:checkpoint, actor, agreement_id, attrs)

  @doc "Retain a result for an exact revision, including late results and no-output findings."
  def submit(actor, agreement_id, attrs), do: mutate(:submit, actor, agreement_id, attrs)

  @doc "Record one human decision on the exact current-revision submission."
  def resolve(actor, agreement_id, attrs), do: mutate(:resolve, actor, agreement_id, attrs)

  @doc "Read current intent and assessments with bounded, immutable record history."
  def read(actor, agreement_id, opts \\ []) do
    with {:ok, context} <- context(actor),
         :ok <- valid_id(agreement_id),
         {:ok, options} <- Validation.options(opts, :before_sequence) do
      Repo.transaction(fn ->
        agreement = fetch!(agreement_id)
        authorize!(:read, context, agreement)
        validate_history_cursor!(agreement, options.before)

        agreement
        |> project()
        |> Map.put("history", history(agreement, options))
      end)
    end
  end

  @doc "List one routine's agreements in stable creation order with their current projections."
  def list(actor, routine_id, opts \\ []) do
    with {:ok, context} <- context(actor),
         :ok <- valid_id(routine_id),
         :ok <- scope_authority(context, routine_id, :read),
         :ok <- configured(routine_id),
         {:ok, options} <- Validation.options(opts, :before_id) do
      Repo.transaction(fn -> list_page(routine_id, options) end)
    end
  end

  defp mutate(action, actor, agreement_id, attrs) do
    with {:ok, context} <- context(actor),
         :ok <- valid_id(agreement_id),
         {:ok, attrs} <- Validation.mutation(action, attrs) do
      fingerprint = fingerprint(action, agreement_id, context, attrs)

      transaction(fn -> mutate_or_retry!(action, context, agreement_id, attrs, fingerprint) end)
    end
  end

  defp create_or_retry!(context, attrs, fingerprint) do
    case retry(context, attrs["request_id"], fingerprint) do
      nil ->
        configured!(attrs["routine_id"])

        agreement =
          Repo.insert!(%Agreement{
            agreement_id: Ecto.UUID.generate(),
            routine_id: attrs["routine_id"]
          })

        append!(agreement, context, attrs, fingerprint, "created", 1)

      record ->
        receipt(record, true)
    end
  end

  defp mutate_or_retry!(action, context, agreement_id, attrs, fingerprint) do
    agreement = fetch!(agreement_id)
    authorize!(action, context, agreement)

    case retry(context, attrs["request_id"], fingerprint) do
      nil -> apply_mutation!(action, agreement, context, attrs, fingerprint)
      record -> receipt(record, true)
    end
  end

  defp apply_mutation!(:revise, agreement, context, attrs, fingerprint) do
    require_current!(agreement, attrs["expected_revision"])
    configured!(agreement.routine_id)
    append!(agreement, context, attrs, fingerprint, "revised", agreement.current_revision + 1)
  end

  defp apply_mutation!(:checkpoint, agreement, context, attrs, fingerprint) do
    require_current!(agreement, attrs["expected_revision"])
    append!(agreement, context, attrs, fingerprint, "checkpoint", agreement.current_revision)
  end

  defp apply_mutation!(:submit, agreement, context, attrs, fingerprint) do
    revision = attrs["agreement_revision"]
    intent = intent!(agreement, revision).payload["intent"]

    if intent["assignment_id"] != attrs["assignment_id"],
      do: Repo.rollback(:assignment_mismatch)

    criteria = MapSet.new(intent["criteria"], & &1["id"])

    unless Enum.all?(attrs["criterion_evidence"], &MapSet.member?(criteria, &1["criterion_id"])),
      do: Repo.rollback(:unknown_criterion)

    append!(agreement, context, attrs, fingerprint, "submission", revision)
  end

  defp apply_mutation!(:resolve, agreement, context, attrs, fingerprint) do
    require_current!(agreement, attrs["expected_revision"])

    submission =
      Repo.get_by(Record,
        record_id: attrs["submission_id"],
        agreement_id: agreement.agreement_id,
        kind: "submission"
      ) || Repo.rollback(:unknown_submission)

    if submission.revision != agreement.current_revision,
      do: Repo.rollback(:submission_revision_mismatch)

    if Repo.get_by(Record, submission_id: submission.record_id),
      do: Repo.rollback(:already_resolved)

    append!(agreement, context, attrs, fingerprint, "resolution", agreement.current_revision)
  end

  defp append!(agreement, context, attrs, fingerprint, kind, revision) do
    sequence = agreement.last_sequence + 1
    current_revision = if kind == "revised", do: revision, else: agreement.current_revision

    agreement
    |> Ecto.Changeset.change(current_revision: current_revision, last_sequence: sequence)
    |> Repo.update!()

    record =
      Repo.insert!(%Record{
        record_id: Ecto.UUID.generate(),
        agreement_id: agreement.agreement_id,
        revision: revision,
        sequence: sequence,
        kind: kind,
        actor_kind: context.kind,
        actor_id: context.id,
        actor_revision: context.execution_revision,
        request_id: attrs["request_id"],
        fingerprint: fingerprint,
        payload: Map.delete(attrs, "request_id"),
        submission_id: if(kind == "resolution", do: attrs["submission_id"])
      })

    receipt(record, false)
  end

  defp retry(context, request_id, fingerprint) do
    case Repo.get_by(Record,
           actor_kind: context.kind,
           actor_id: context.id,
           request_id: request_id
         ) do
      nil -> nil
      %Record{fingerprint: ^fingerprint} = record -> record
      %Record{} -> Repo.rollback(:idempotency_conflict)
    end
  end

  defp require_current!(%Agreement{current_revision: revision}, revision), do: :ok
  defp require_current!(_agreement, _revision), do: Repo.rollback(:revision_conflict)

  defp fetch!(id),
    do: Repo.get_by(Agreement, agreement_id: id) || Repo.rollback(:not_found)

  defp intent!(agreement, revision) do
    Repo.one(
      from(r in Record,
        where:
          r.agreement_id == ^agreement.agreement_id and r.revision == ^revision and
            r.kind in ["created", "revised"],
        limit: 1
      )
    ) || Repo.rollback(:unknown_revision)
  end

  defp latest(agreement, kind) do
    Repo.one(
      from(r in Record,
        where:
          r.agreement_id == ^agreement.agreement_id and
            r.revision == ^agreement.current_revision and r.kind == ^kind,
        order_by: [desc: r.sequence],
        limit: 1
      )
    )
  end

  defp project(agreement) do
    intent = intent!(agreement, agreement.current_revision)
    checkpoint = latest(agreement, "checkpoint")
    submission = latest(agreement, "submission")
    resolution = submission && Repo.get_by(Record, submission_id: submission.record_id)

    %{
      "schema_version" => "custode.work_agreement.v1",
      "source" => "work_agreements",
      "evidence" => "attributed_bookkeeping",
      "effect_authority" => "none",
      "agreement_id" => agreement.agreement_id,
      "routine_id" => agreement.routine_id,
      "owner_id" => agreement.routine_id,
      "current_revision" => agreement.current_revision,
      "last_sequence" => agreement.last_sequence,
      "created_at" => iso(agreement.inserted_at),
      "updated_at" => iso(agreement.updated_at),
      "observed_at" => now(),
      "current" => %{
        "intent" => intent.payload["intent"],
        "intent_record" => public_record(intent),
        "checkpoint" => public_record(checkpoint),
        "submission" => public_record(submission),
        "resolution" => public_record(resolution),
        "status" => status(submission, resolution)
      }
    }
  end

  defp status(nil, _resolution), do: "open"
  defp status(_submission, nil), do: "submitted"
  defp status(_submission, resolution), do: resolution.payload["outcome"]

  defp history(agreement, options) do
    query = from(r in Record, where: r.agreement_id == ^agreement.agreement_id)

    query =
      if options.before,
        do: from(r in query, where: r.sequence < ^options.before),
        else: query

    rows = Repo.all(from(r in query, order_by: [desc: r.sequence], limit: ^(options.limit + 1)))
    selected = Enum.take(rows, options.limit)
    has_more = length(rows) > options.limit

    %{
      "records" => Enum.map(selected, &public_record/1),
      "has_more" => has_more,
      "before_sequence" => if(has_more, do: List.last(selected).sequence)
    }
  end

  defp validate_history_cursor!(_agreement, nil), do: :ok

  defp validate_history_cursor!(agreement, before) do
    if before > agreement.last_sequence, do: Repo.rollback(:invalid_cursor)
  end

  defp list_page(routine_id, options) do
    query = from(a in Agreement, where: a.routine_id == ^routine_id)

    query =
      case options.before do
        nil ->
          query

        before ->
          boundary =
            Repo.get_by(Agreement, agreement_id: before, routine_id: routine_id) ||
              Repo.rollback(:invalid_cursor)

          from(a in query, where: a.id < ^boundary.id)
      end

    rows = Repo.all(from(a in query, order_by: [desc: a.id], limit: ^(options.limit + 1)))
    selected = Enum.take(rows, options.limit)
    has_more = length(rows) > options.limit

    %{
      "schema_version" => "custode.work_agreement_list.v1",
      "source" => "work_agreements",
      "evidence" => "attributed_bookkeeping",
      "routine_id" => routine_id,
      "observed_at" => now(),
      "agreements" => Enum.map(selected, &project/1),
      "has_more" => has_more,
      "before_id" => if(has_more, do: List.last(selected).agreement_id)
    }
  end

  defp public_record(nil), do: nil

  defp public_record(record) do
    %{
      "record_id" => record.record_id,
      "agreement_id" => record.agreement_id,
      "revision" => record.revision,
      "sequence" => record.sequence,
      "kind" => record.kind,
      "payload" => record.payload,
      "recorded_at" => iso(record.inserted_at),
      "recorded_by" => recorded_by(record),
      "source" => "work_agreement_records",
      "evidence" => "attributed_bookkeeping"
    }
  end

  defp receipt(record, duplicate) do
    %{
      "schema_version" => "custode.work_agreement_mutation.v1",
      "agreement_id" => record.agreement_id,
      "revision" => record.revision,
      "sequence" => record.sequence,
      "record_id" => record.record_id,
      "kind" => record.kind,
      "recorded_at" => iso(record.inserted_at),
      "recorded_by" => recorded_by(record),
      "duplicate" => duplicate
    }
  end

  defp recorded_by(record) do
    %{
      "kind" => record.actor_kind,
      "id" => record.actor_id,
      "execution_revision" => record.actor_revision
    }
  end

  defp context(%{kind: :operator, id: id}) do
    if Validation.id?(id),
      do: {:ok, %{kind: "operator", id: id, role: nil, execution_revision: nil}},
      else: {:error, :unauthenticated}
  end

  defp context(%{kind: :routine, id: id}) do
    with :ok <- valid_actor_id(id),
         :ok <- configured(id),
         {:ok, captured} <- captured_authority(id) do
      {:ok,
       %{
         kind: "routine",
         id: id,
         role: captured.role,
         execution_revision: captured.execution_revision
       }}
    end
  end

  defp context(%{kind: :sub_agent}), do: {:error, :forbidden}
  defp context(_actor), do: {:error, :unauthenticated}

  defp captured_authority(id) do
    case AgentHandoff.authorization_routine(id) do
      {:ok, captured} -> {:ok, captured}
      {:error, _reason} -> {:error, :authorization_unavailable}
    end
  end

  defp authorize!(action, context, agreement) do
    case scope_authority(context, agreement.routine_id, action) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp scope_authority(%{kind: "operator"}, _owner, _action), do: :ok

  defp scope_authority(context, _owner, :revise), do: manage_authority(context)

  defp scope_authority(%{role: :caretaker}, _owner, :read), do: :ok

  defp scope_authority(%{kind: "routine", id: owner}, owner, action)
       when action in [:read, :checkpoint, :submit],
       do: :ok

  defp scope_authority(_context, _owner, _action), do: {:error, :forbidden}

  defp manage_authority(%{kind: "operator"}), do: :ok
  defp manage_authority(%{kind: "routine", role: :caretaker}), do: :ok
  defp manage_authority(_context), do: {:error, :forbidden}

  defp configured(id) do
    if Routine.get(id), do: :ok, else: {:error, :unknown_routine}
  end

  defp configured!(id) do
    case configured(id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp valid_id(id) do
    if Validation.id?(id), do: :ok, else: {:error, :invalid_arguments}
  end

  defp valid_actor_id(id) do
    if Validation.id?(id), do: :ok, else: {:error, :unauthenticated}
  end

  defp fingerprint(action, agreement_id, context, attrs) do
    {action, agreement_id, context.kind, context.id, canonical(attrs)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value),
    do: value |> Enum.map(fn {key, entry} -> {key, canonical(entry)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp transaction(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, %{"duplicate" => false, "agreement_id" => id} = receipt} ->
        agreement = Repo.get_by!(Agreement, agreement_id: id)
        Custode.PubSubBridge.broadcast({:work_agreement_changed, agreement.routine_id})
        {:ok, receipt}

      result ->
        result
    end
  end

  defp iso(value), do: DateTime.to_iso8601(value)
  defp now, do: DateTime.utc_now() |> iso()
end
