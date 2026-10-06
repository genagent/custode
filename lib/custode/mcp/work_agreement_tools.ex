defmodule Custode.MCP.WorkAgreementTools do
  @moduledoc "Thin adapters for attributed work-agreement bookkeeping; no tool dispatches work."

  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  alias Custode.WorkAgreements

  @reference_kinds ~w(operator_message peer_message helper_epoch report document assurance github url other)

  @doc false
  def schema(:create),
    do:
      object(
        %{"request_id" => id(), "routine_id" => id(), "intent" => intent()},
        ~w(request_id routine_id intent)
      )

  def schema(:revise),
    do:
      mutation(
        %{"expected_revision" => revision(), "intent" => intent()},
        ~w(expected_revision intent)
      )

  def schema(:checkpoint),
    do:
      mutation(
        %{
          "expected_revision" => revision(),
          "summary" => prose(),
          "next_steps" => collection(step()),
          "blockers" => collection(obligation()),
          "decisions" => collection(obligation())
        },
        ~w(expected_revision summary)
      )

  def schema(:submit),
    do:
      mutation(
        %{
          "agreement_revision" => revision(),
          "assignment_id" => id(),
          "summary" => prose(),
          "outputs" => references(),
          "criterion_evidence" => Map.put(collection(evidence()), "minItems", 1),
          "verification_limits" => prose()
        },
        ~w(agreement_revision assignment_id summary criterion_evidence verification_limits)
      )

  def schema(:resolve),
    do:
      mutation(
        %{
          "expected_revision" => revision(),
          "submission_id" => id(),
          "outcome" => %{"type" => "string", "enum" => ~w(accepted changes_requested rejected)},
          "reason" => prose()
        },
        ~w(expected_revision submission_id outcome reason)
      )

  def schema(:read),
    do:
      object(
        %{
          "agreement_id" => Map.put(id(), "description", "read one agreement; omit routine_id"),
          "routine_id" =>
            Map.put(id(), "description", "list one routine's agreements; omit agreement_id"),
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 100,
            "description" => "records or agreements per page; default 20"
          },
          "before_sequence" =>
            Map.put(revision(), "description", "history cursor for agreement_id reads only"),
          "before_id" =>
            Map.put(id(), "description", "agreement cursor for routine_id lists only")
        },
        []
      )

  defp mutation(properties, required) do
    object(
      Map.merge(%{"agreement_id" => id(), "request_id" => id()}, properties),
      ["agreement_id", "request_id" | required]
    )
  end

  defp intent do
    object(
      %{
        "outcome" => prose(),
        "criteria" =>
          Map.put(
            collection(object(%{"id" => id(), "text" => prose()}, ~w(id text))),
            "minItems",
            1
          ),
        "boundaries" => collection(prose()),
        "assignment_id" => id(),
        "request_references" => references(),
        "inputs" => references(),
        "expected_outputs" => references()
      },
      ~w(outcome criteria assignment_id)
    )
  end

  defp reference do
    object(
      %{
        "kind" => %{"type" => "string", "enum" => @reference_kinds},
        "value" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 2048,
          "description" => "opaque reference; never opened, fetched, verified or executed"
        },
        "revision" => id(),
        "label" => %{"type" => "string", "minLength" => 1, "maxLength" => 200}
      },
      ~w(kind value)
    )
  end

  defp step,
    do: object(%{"id" => id(), "text" => prose(), "references" => references()}, ~w(id text))

  defp obligation,
    do:
      object(
        %{
          "id" => id(),
          "text" => prose(),
          "references" => references(),
          "resolver" =>
            object(
              %{
                "kind" => %{"type" => "string", "enum" => ~w(operator routine external)},
                "id" => id()
              },
              ~w(kind id)
            )
        },
        ~w(id text resolver)
      )

  defp evidence,
    do:
      object(
        %{"criterion_id" => id(), "references" => references(), "note" => prose()},
        ~w(criterion_id references note)
      )

  defp id, do: %{"type" => "string", "minLength" => 1, "maxLength" => 160}
  defp prose, do: %{"type" => "string", "minLength" => 1, "maxLength" => 2000}

  defp revision,
    do: %{"type" => "integer", "minimum" => 1, "maximum" => 9_223_372_036_854_775_807}

  defp references, do: collection(reference())
  defp collection(item), do: %{"type" => "array", "maxItems" => 20, "items" => item}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  @doc false
  def execute(operation, params, frame) do
    with {:ok, actor} <- actor(frame),
         {:ok, attrs} <- arguments(params, schema(operation)),
         {:ok, result} <- invoke(operation, actor, attrs) do
      reply(frame, result)
    else
      {:error, reason} -> fail(frame, error_text(reason))
    end
  end

  defp actor(%{assigns: %{custode_identity: %{kind: kind, id: id} = actor}})
       when kind in [:operator, :routine] and is_binary(id) do
    if String.valid?(id) and String.trim(id) != "",
      do: {:ok, actor},
      else: {:error, :unauthenticated}
  end

  defp actor(_frame), do: {:error, :unauthenticated}

  # Native calls already normalize schema fields. Direct adapters still reject
  # unknown or duplicate top-level names rather than dropping supplied intent.
  defp arguments(params, schema) when is_map(params) do
    names = Map.new(Map.keys(schema["properties"]), &{&1, String.to_existing_atom(&1)})

    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, attrs} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key
      field = Map.get(names, name)

      if field && not Map.has_key?(attrs, field),
        do: {:cont, {:ok, Map.put(attrs, field, value)}},
        else: {:halt, {:error, :invalid_arguments}}
    end)
  end

  defp arguments(_params, _schema), do: {:error, :invalid_arguments}

  defp invoke(:create, actor, attrs), do: WorkAgreements.create(actor, attrs)

  defp invoke(:read, actor, attrs) do
    case {Map.get(attrs, :agreement_id), Map.get(attrs, :routine_id)} do
      {id, nil} when is_binary(id) ->
        if Map.has_key?(attrs, :before_id),
          do: {:error, :invalid_read_selector},
          else: WorkAgreements.read(actor, id, options(attrs, [:limit, :before_sequence]))

      {nil, id} when is_binary(id) ->
        if Map.has_key?(attrs, :before_sequence),
          do: {:error, :invalid_read_selector},
          else: WorkAgreements.list(actor, id, options(attrs, [:limit, :before_id]))

      _invalid ->
        {:error, :invalid_read_selector}
    end
  end

  defp invoke(operation, actor, attrs) do
    {agreement_id, attrs} = Map.pop(attrs, :agreement_id)
    apply(WorkAgreements, operation, [actor, agreement_id, attrs])
  end

  defp options(attrs, keys), do: for(key <- keys, Map.has_key?(attrs, key), do: {key, attrs[key]})

  defp error_text(:unauthenticated),
    do: "work agreements require an authenticated operator or routine identity"

  defp error_text(:forbidden), do: "work agreement access denied for this identity and operation"
  defp error_text(:unknown_routine), do: "routine_id must name a configured routine"
  defp error_text(:not_found), do: "work agreement not found or not visible to this identity"

  defp error_text(:invalid_read_selector),
    do:
      "provide exactly one of agreement_id or routine_id; before_sequence applies to agreement history, before_id to routine lists"

  defp error_text(:invalid_arguments),
    do: "invalid work agreement arguments; load this tool's schema"

  defp error_text(:invalid_cursor),
    do: "invalid cursor; use the cursor returned for this agreement or routine"

  defp error_text(:authorization_unavailable),
    do: "routine authorization is unavailable; retry after its configuration handoff"

  defp error_text(:revision_conflict),
    do: "revision conflict; read the current agreement before making a new change"

  defp error_text(:idempotency_conflict),
    do:
      "request_id already names different work; retry its original arguments or use a new request_id"

  defp error_text(:unknown_revision),
    do: "agreement_revision does not name a retained agreement revision"

  defp error_text(:unknown_submission),
    do: "submission_id does not name a submission in this agreement"

  defp error_text(:submission_revision_mismatch),
    do: "submission revision is not current; historical submissions cannot resolve current work"

  defp error_text(:assignment_mismatch),
    do: "assignment_id must match the referenced agreement revision"

  defp error_text(:unknown_criterion),
    do: "criterion evidence must name criteria from the referenced agreement revision"

  defp error_text(:already_resolved),
    do: "this submission already has a resolution; submit a new result for another decision"

  defp error_text(reason) when is_binary(reason), do: reason

  defp error_text(_reason),
    do: "work agreement request refused; check the tool schema and current agreement"
end

defmodule Custode.MCP.WorkAgreementTools.Create do
  @moduledoc "Record an agreement for a configured routine. Operator or caretaker only. Records intent and assignment references without starting work; retry the same request_id and payload after an uncertain response."
  use Custode.MCP.Tool, name: "work_agreement_create", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:create))

  @impl true
  def execute(params, frame), do: WorkAgreementTools.execute(:create, params, frame)
end

defmodule Custode.MCP.WorkAgreementTools.Revise do
  @moduledoc "Replace current agreement intent with an expected-revision check. Operator or caretaker only. Preserves prior work and acceptance history without inheriting acceptance or dispatching a new assignment."
  use Custode.MCP.Tool, name: "work_agreement_revise", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:revise))

  @impl true
  def execute(params, frame), do: WorkAgreementTools.execute(:revise, params, frame)
end

defmodule Custode.MCP.WorkAgreementTools.Checkpoint do
  @moduledoc "Record an attributed checkpoint, next steps, blockers and decisions for the current agreement revision. Human operator or the owning routine only; assessments do not prove execution or acceptance."
  use Custode.MCP.Tool, name: "work_agreement_checkpoint", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:checkpoint))

  @impl true
  def execute(params, frame),
    do: WorkAgreementTools.execute(:checkpoint, params, frame)
end

defmodule Custode.MCP.WorkAgreementTools.Submit do
  @moduledoc "Submit an outcome, criterion evidence and verification limits for a named agreement revision and assignment. Human operator or owning routine only. Historical results remain visible but do not complete current work. Empty outputs can describe useful negative findings."
  use Custode.MCP.Tool, name: "work_agreement_submit", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:submit))

  @impl true
  def execute(params, frame), do: WorkAgreementTools.execute(:submit, params, frame)
end

defmodule Custode.MCP.WorkAgreementTools.Resolve do
  @moduledoc "Record a human resolution of an exact current-revision submission. Authenticated operator only. Acceptance is agreement bookkeeping and grants no execution, gate, shell or Assurance authority."
  use Custode.MCP.Tool, name: "work_agreement_resolve", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:resolve))

  @impl true
  def execute(params, frame), do: WorkAgreementTools.execute(:resolve, params, frame)
end

defmodule Custode.MCP.WorkAgreementTools.Read do
  @moduledoc "Read one agreement and bounded history, or list one routine’s agreements with their current projections. Human operator and caretaker may inspect all; other routines only their own. No wake-up, source dereference or mutation."
  use Custode.MCP.Tool, name: "work_agreement_read", strict_arguments: true

  alias Custode.MCP.WorkAgreementTools

  input_schema(WorkAgreementTools.schema(:read))

  @impl true
  def execute(params, frame), do: WorkAgreementTools.execute(:read, params, frame)
end
