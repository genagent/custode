defmodule Custode.Assurance do
  @moduledoc """
  Opt-in owner assurance records in the operations store. Operator recording is
  separate from read projection and from repository effect authority.
  """
  import Ecto.Query, only: [from: 2]
  alias Custode.{AgentHandoff, Repo, Repository, Routine}
  alias Custode.Assurance.{Evaluator, Sources}
  alias Snodo.Schema.Validator.Basic

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :string, autogenerate: false}
    schema "assurance_records" do
      field(:case_id, :string)
      field(:kind, :string)
      field(:fingerprint, :string)
      field(:record, :map)
    end
  end

  @bindings ~w(case_revision artifact_revision policy_digest generation)
  @classes ~w(self_reported host_observed external_attested independent_opinion independently_reproduced)
  @sources ~w(owner_review document execution repository_check)

  @doc "Freeze one configured assignment and its initial logical attempt. No work is launched."
  def open(actor, request) do
    with :ok <- operator(actor),
         :ok <- validate(request, open_schema()),
         {:ok, assignment} <- assignment(request["assignment_id"]),
         {:ok, owner_revision} <- current_owner(assignment["owner_id"]),
         :ok <- validate_artifact(assignment["owner_id"], request["artifact"]) do
      fingerprint = digest({actor, request})
      id = request["case_id"]

      transaction(fn -> open_record!(id, assignment, request, owner_revision, fingerprint) end)
    end
  end

  @doc "Start a new bounded revision; old attempts and their receipts are immutable."
  def revise(actor, case_id, request) do
    with :ok <- operator(actor), :ok <- validate(request, revise_schema()) do
      event(actor, case_id, request, "revision", &revise_record!(&1, request))
    end
  end

  @doc "Record only source references. Caller-issued classes and payloads are refused."
  def capture(actor, case_id, request) do
    with :ok <- operator(actor), :ok <- validate(request, capture_schema()) do
      event(actor, case_id, request, "evidence", &capture_record!(actor, &1, request))
    end
  end

  @doc "Retain the designated human judge's exact-bound opinion, without approving an effect."
  def judge(actor, case_id, request) do
    with :ok <- operator(actor), :ok <- validate(request, judge_schema()) do
      event(actor, case_id, request, "evidence", &judge_record!(actor, &1, request))
    end
  end

  @doc "Retain an explainable decision over the exact evidence ids available now."
  def decide(actor, case_id, request) do
    with :ok <- operator(actor), :ok <- validate(request, event_schema()) do
      event(actor, case_id, request, "decision", fn record ->
        {:ok, evaluate(record) |> Map.put("id", request["request_id"])}
      end)
    end
  end

  @doc "Compact current read with historical references. Reading never records or launches work."
  def read(actor, case_id) when is_binary(case_id) do
    with %Row{} = row <- Repo.get(Row, "case:" <> case_id),
         :ok <- read_scope(actor, row.record["owner_id"]) do
      events = events(case_id)

      {:ok,
       %{
         "schema_version" => "custode.assurance.v1",
         "case_id" => case_id,
         "assignment_id" => row.record["assignment_id"],
         "owner_id" => row.record["owner_id"],
         "current" =>
           Map.take(row.record["current"], @bindings ++ ~w(judge_id criteria producer artifact)),
         "max_rounds" => row.record["max_rounds"],
         "attempts" => Enum.map(row.record["attempts"], &Map.take(&1, @bindings)),
         "evaluation" => evaluate(row.record),
         "evidence" =>
           for(
             event <- events,
             event.kind == "evidence",
             do: Map.drop(event.record, ["snapshot"])
           ),
         "decisions" => for(event <- events, event.kind == "decision", do: event.record),
         "effect_authority" => "none"
       }}
    else
      nil -> {:error, :unknown_case}
      error -> error
    end
  end

  def read(_actor, _case_id), do: {:error, :invalid_case_id}

  @doc "Exact frozen input to an evidence-only OwnerReviews request."
  def review_input(actor, case_id) do
    with %Row{} = row <- Repo.get(Row, "case:" <> case_id),
         :ok <- read_scope(actor, row.record["owner_id"]) do
      {:ok, Sources.review_input(row.record["current"])}
    else
      nil -> {:error, :unknown_case}
      error -> error
    end
  end

  defp event(actor, case_id, request, kind, observe) do
    fingerprint = digest({actor, case_id, kind, request})

    with %Row{} = row <- Repo.get(Row, "case:" <> case_id),
         {:ok, _assignment} <- configured(row.record) do
      prepare_event(row.record, request, kind, fingerprint, observe)
    else
      nil -> {:error, :unknown_case}
      error -> error
    end
  end

  defp prepare_event(record, request, kind, fingerprint, observe) do
    case Repo.get(Row, "event:" <> request["request_id"]) do
      %Row{fingerprint: ^fingerprint} = event -> {:ok, event.record}
      %Row{} -> {:error, :idempotency_conflict}
      nil -> observe_event(record, request, kind, fingerprint, observe)
    end
  end

  defp observe_event(record, request, kind, fingerprint, observe) do
    if request["generation"] == record["current"]["generation"] do
      with {:ok, observed} <- observe.(record) do
        persist_observation(record["case_id"], request, kind, fingerprint, observed)
      end
    else
      {:error, :stale_generation}
    end
  end

  defp persist_observation(case_id, request, kind, fingerprint, observed) do
    transaction(fn -> store_event!(case_id, request, kind, fingerprint, observed) end)
  end

  defp open_record!(id, assignment, request, owner_revision, fingerprint) do
    case Repo.get(Row, "case:" <> id) do
      %Row{fingerprint: ^fingerprint} = row ->
        row.record

      %Row{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        attempt = freeze(assignment, request, owner_revision, 1)

        record = %{
          "schema_version" => "custode.assurance.v1",
          "case_id" => id,
          "assignment_id" => assignment["id"],
          "owner_id" => assignment["owner_id"],
          "max_rounds" => assignment["max_rounds"],
          "current" => attempt,
          "attempts" => [attempt]
        }

        Repo.insert!(%Row{
          id: "case:" <> id,
          case_id: id,
          kind: "case",
          fingerprint: fingerprint,
          record: record
        })

        record
    end
  end

  defp revise_record!(record, request) do
    with {:ok, assignment} <- configured(record),
         {:ok, owner_revision} <- current_owner(record["owner_id"]),
         :ok <- validate_artifact(record["owner_id"], request["artifact"]) do
      if record["current"]["generation"] >= record["max_rounds"] do
        {:error, :revision_round_bound}
      else
        {:ok, freeze(assignment, request, owner_revision, record["current"]["generation"] + 1)}
      end
    end
  end

  defp capture_record!(actor, record, request) do
    attempt = record["current"]
    predicate = Enum.find(attempt["policy"]["predicates"], &(&1["name"] == request["predicate"]))

    if is_nil(predicate) or request["source"]["kind"] not in predicate["sources"] do
      {:error, :predicate_source_mismatch}
    else
      with {:ok, observed} <- Sources.capture(actor, record, request["source"]) do
        {:ok,
         Map.merge(observed, %{
           "id" => request["request_id"],
           "predicate" => request["predicate"],
           "issuer" => "custode.assurance.v1",
           "custody_class" => "host_observed",
           "binding" => Map.take(attempt, @bindings)
         })}
      end
    end
  end

  defp judge_record!(actor, record, request) do
    attempt = record["current"]

    if actor.id == attempt["judge_id"] do
      {:ok,
       %{
         "id" => request["request_id"],
         "kind" => "judge",
         "actor" => actor.id,
         "predicate" => "designated_judge",
         "issuer" => "custode.assurance.v1",
         "custody_class" => "host_observed",
         "claim_class" => "designated_judge",
         "outcome" => request["outcome"],
         "reason" => request["reason"],
         "binding" => Map.take(attempt, @bindings),
         "effect_authority" => "none"
       }}
    else
      {:error, :designated_judge_required}
    end
  end

  defp store_event!(case_id, request, kind, fingerprint, observed) do
    row = Repo.get(Row, "case:" <> case_id) || Repo.rollback(:unknown_case)
    record = row.record

    case Repo.get(Row, "event:" <> request["request_id"]) do
      %Row{fingerprint: ^fingerprint} = event -> event.record
      %Row{} -> Repo.rollback(:idempotency_conflict)
      nil -> insert_event!(record, request, kind, fingerprint, observed)
    end
  end

  defp insert_event!(record, request, kind, fingerprint, observed) do
    if request["generation"] != record["current"]["generation"],
      do: Repo.rollback(:stale_generation)

    if length(events(record["case_id"])) >= 256, do: Repo.rollback(:record_bound)

    if kind == "revision" do
      next =
        record |> Map.put("current", observed) |> Map.update!("attempts", &(&1 ++ [observed]))

      row = Repo.get!(Row, "case:" <> record["case_id"])
      row |> Ecto.Changeset.change(record: next) |> Repo.update!()
    end

    row =
      Repo.insert!(%Row{
        id: "event:" <> request["request_id"],
        case_id: record["case_id"],
        kind: kind,
        fingerprint: fingerprint,
        record: Map.put(observed, "recorded_at", DateTime.to_iso8601(DateTime.utc_now()))
      })

    row.record
  end

  defp configured(record) do
    with {:ok, assignment} <- assignment(record["assignment_id"]),
         true <- assignment["owner_id"] == record["owner_id"],
         {:ok, _revision} <- current_owner(record["owner_id"]) do
      {:ok, assignment}
    else
      _unavailable -> {:error, :assignment_unavailable}
    end
  end

  defp evaluate(record) do
    current_digest =
      case assignment(record["assignment_id"]) do
        {:ok, assignment} -> policy_digest(assignment)
        _unavailable -> nil
      end

    evidence = for(event <- events(record["case_id"]), event.kind == "evidence", do: event.record)
    Evaluator.evaluate(record["current"], evidence, current_digest)
  end

  defp events(case_id),
    do:
      Repo.all(
        from(row in Row,
          where: row.case_id == ^case_id and row.kind != "case",
          order_by: [asc: row.id]
        )
      )

  defp transaction(fun), do: Repo.transaction(fun, mode: :immediate)

  defp freeze(assignment, request, owner_revision, generation) do
    frozen = %{
      "objective" => request["objective"],
      "input" => request["input"],
      "objective_revision" => digest(request["objective"]),
      "input_revision" => digest(request["input"]),
      "artifact" => request["artifact"],
      "artifact_revision" => digest(request["artifact"]),
      "criteria" => assignment["criteria"],
      "criteria_revision" => digest(assignment["criteria"]),
      "policy" => assignment["policy"],
      "policy_digest" => policy_digest(assignment),
      "judge_id" => assignment["judge_id"],
      "owner_revision" => owner_revision,
      "producer" => Sources.producer(assignment["owner_id"], request["producer_job_id"]),
      "generation" => generation
    }

    Map.put(frozen, "case_revision", digest(frozen))
  end

  defp validate_artifact(owner_id, %{
         "kind" => "repository",
         "repository" => repository,
         "revision" => revision
       }) do
    owner = Routine.get(owner_id)

    if owner.repo != repository or Repository.well_formed(repository) == nil or
         not Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
       do: {:error, :artifact_scope_unavailable},
       else: :ok
  end

  defp validate_artifact(_owner_id, %{"kind" => "document", "root_id" => root, "path" => path}) do
    if not is_binary(root) or not is_binary(path),
      do: {:error, :artifact_scope_unavailable},
      else: :ok
  end

  defp validate_artifact(_owner_id, _artifact), do: {:error, :artifact_scope_unavailable}

  defp policy_digest(assignment),
    do: digest(Map.take(assignment, ~w(id owner_id judge_id max_rounds criteria policy)))

  defp assignment(id) do
    definitions = Application.get_env(:custode, :assurance_assignments, []) |> json()
    matches = if is_list(definitions), do: Enum.filter(definitions, &(&1["id"] == id)), else: []

    case matches do
      [definition] ->
        if valid_assignment?(definition),
          do: {:ok, definition},
          else: {:error, :invalid_assignment}

      _unknown ->
        {:error, :assignment_unavailable}
    end
  end

  defp valid_assignment?(definition) do
    validate(definition, assignment_schema()) == :ok and
      length(Enum.uniq_by(definition["policy"]["predicates"], & &1["name"])) ==
        length(definition["policy"]["predicates"]) and
      Enum.all?(definition["policy"]["predicates"], &(&1["name"] != "designated_judge"))
  end

  defp current_owner(id) do
    with {:ok, captured} <- AgentHandoff.authorization_routine(id),
         %{} = owner <- Routine.get(id),
         true <- captured.execution_revision == Routine.execution_revision(owner) do
      {:ok, captured.execution_revision}
    else
      _unavailable -> {:error, :owner_scope_unavailable}
    end
  end

  defp operator(%{kind: :operator, id: id}) when is_binary(id) and id != "", do: :ok
  defp operator(_actor), do: {:error, :operator_required}
  defp read_scope(%{kind: :operator, id: id}, _owner) when is_binary(id) and id != "", do: :ok

  defp read_scope(%{kind: :routine, id: id}, id) do
    case current_owner(id) do
      {:ok, _revision} -> :ok
      error -> error
    end
  end

  defp read_scope(_actor, _owner), do: {:error, :owner_scope_unavailable}

  defp validate(value, schema) do
    case Basic.validate(value, schema) do
      :ok -> :ok
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp text(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}

  defp object(required, properties),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }

  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp integer(min, max), do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  defp artifact_schema do
    object(~w(kind revision), %{
      "kind" => enum(~w(document repository)),
      "revision" => text(160),
      "root_id" => text(160),
      "path" => text(200),
      "repository" => text(160)
    })
  end

  defp inputs,
    do: %{
      "objective" => text(16_384),
      "input" => text(100_000),
      "artifact" => artifact_schema(),
      "producer_job_id" => integer(1, 2_147_483_647)
    }

  defp open_schema,
    do:
      object(
        ~w(case_id assignment_id objective input artifact),
        Map.merge(inputs(), %{"case_id" => text(160), "assignment_id" => text(160)})
      )

  defp revise_schema,
    do:
      object(
        ~w(request_id generation objective input artifact),
        Map.merge(inputs(), event_properties())
      )

  defp event_properties, do: %{"request_id" => text(160), "generation" => integer(1, 16)}
  defp event_schema, do: object(~w(request_id generation), event_properties())

  defp judge_schema,
    do:
      object(
        ~w(request_id generation outcome reason),
        Map.merge(event_properties(), %{
          "outcome" => enum(~w(passed failed unknown)),
          "reason" => text(4000)
        })
      )

  defp capture_schema do
    source =
      object(["kind"], %{
        "kind" => enum(@sources),
        "review_id" => text(160),
        "slot" => integer(1, 2),
        "request_id" => text(160),
        "job_id" => integer(1, 2_147_483_647),
        "name" => text(200)
      })

    object(
      ~w(request_id generation predicate source),
      Map.merge(event_properties(), %{"predicate" => text(160), "source" => source})
    )
  end

  defp assignment_schema do
    predicate =
      object(~w(name sources classes independent), %{
        "name" => text(160),
        "sources" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 4,
          "items" => enum(@sources)
        },
        "classes" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 5,
          "items" => enum(@classes)
        },
        "independent" => %{"type" => "boolean"}
      })

    object(~w(id owner_id judge_id max_rounds criteria policy), %{
      "id" => text(160),
      "owner_id" => text(160),
      "judge_id" => text(160),
      "max_rounds" => integer(1, 16),
      "criteria" => %{"type" => "array", "minItems" => 1, "maxItems" => 16, "items" => text(2000)},
      "policy" =>
        object(["predicates"], %{
          "predicates" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 16,
            "items" => predicate
          }
        })
    })
  end

  @doc false
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
