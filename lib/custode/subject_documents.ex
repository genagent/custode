defmodule Custode.SubjectDocuments do
  @moduledoc "Bounded documents in explicitly granted, persistent roots; references confer no writes."
  import Ecto.Query, only: [from: 2]
  alias Custode.{AgentHandoff, ExecutionFacts, Feed, Repo, SubAgents, SubjectDocumentBridge}
  alias Snodo.Schema.Validator.Basic

  defmodule Operation do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:request_id, :string, autogenerate: false}
    schema "subject_document_operations" do
      field(:root_id, :string)
      field(:fingerprint, :string)
      field(:record, :map)
    end
  end

  @actions ~w(roots browse read search create propose receipt history diff)
  @read_actions ~w(browse read search receipt history diff)
  @mutation_actions ~w(create propose)

  def invoke(actor, params) do
    with :ok <- valid_params(params), :ok <- current_identity(actor) do
      perform(actor, params)
    end
  end

  defp perform(actor, %{"action" => "roots"}) do
    roots =
      for definition <- definitions(), grant = grant(actor, definition), grant != nil do
        %{
          root_id: definition.id,
          subject: definition.subject,
          limits: %{file_bytes: 16_384, files: 100, search_bytes: 100_000},
          binding: "persistent_directory_identity",
          layout: "direct_child_markdown_only",
          read_paths: grant.read_paths,
          create_paths: grant.create_paths,
          propose_paths: grant.propose_paths,
          proposal_destinations: grant.proposal_destinations,
          unavailable: ~w(recursive_paths git_history git_diff automatic_apply automatic_commit)
        }
      end

    {:ok, json(%{schema_version: "custode.subject_roots.v1", roots: roots})}
  end

  defp perform(actor, params) do
    with {:ok, definition, access} <- authorized_root(actor, params) do
      operation(actor, definition, access, params)
    end
  end

  defp operation(_actor, _definition, _access, %{"action" => action})
       when action in ~w(history diff),
       do: {:error, "git_boundary_unavailable"}

  defp operation(actor, definition, _access, %{"action" => action} = params)
       when action in @mutation_actions,
       do: mutation(actor, definition, params)

  defp operation(_actor, definition, access, %{"action" => "receipt"} = params),
    do: receipt(definition, access, params["request_id"])

  defp operation(_actor, definition, access, params) do
    request = Map.put(params, "allowed_paths", access.read_paths)

    with {:ok, result} <- SubjectDocumentBridge.invoke(definition, request) do
      {:ok, decorate(definition, result)}
    end
  end

  defp mutation(actor, definition, params) do
    fingerprint = digest({actor, definition, params})

    with {:ok, binding} <- SubjectDocumentBridge.invoke(definition, %{"action" => "binding"}),
         {:ok, record} <- prepare(actor, definition, params, fingerprint, binding) do
      execute_prepared(definition, params, record)
    end
  end

  defp prepare(actor, definition, params, fingerprint, binding) do
    producer = producer(actor)

    record = %{
      "request_id" => params["request_id"],
      "request" => params,
      "actor" => json(actor),
      "producer" => producer,
      "grant_revision" => digest(definition),
      "binding" => binding,
      "status" => "prepared",
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "result" => nil,
      "error" => nil
    }

    Repo.transaction(fn -> store_or_retry!(definition, params, fingerprint, record) end,
      mode: :immediate
    )
  end

  defp store_or_retry!(definition, params, fingerprint, record) do
    case Repo.get(Operation, params["request_id"]) do
      %Operation{fingerprint: ^fingerprint} = row ->
        {"existing", row.record}

      %Operation{} ->
        Repo.rollback("idempotency_conflict")

      nil ->
        Repo.insert!(%Operation{
          request_id: params["request_id"],
          root_id: definition.id,
          fingerprint: fingerprint,
          record: record
        })

        {"new", record}
    end
  end

  defp execute_prepared(_definition, _params, {"existing", %{"status" => "prepared"}}),
    do: {:error, "operation_unconfirmed_do_not_retry_write"}

  defp execute_prepared(_definition, _params, {"existing", record}), do: result(record)

  defp execute_prepared(definition, params, {"new", _record}) do
    outcome = SubjectDocumentBridge.invoke(definition, params)
    finalize(definition, params, outcome)
  end

  defp finalize(definition, params, outcome) do
    {status, value, error} =
      case outcome do
        {:ok, value} ->
          {"created",
           Map.put(
             decorate(definition, value),
             "source",
             "published_receipt_current_read_required"
           ), nil}

        {:error, error} ->
          {"refused_or_unconfirmed", nil, error}
      end

    {:ok, {record, event}} =
      Repo.transaction(
        fn ->
          row = Repo.get!(Operation, params["request_id"])

          record =
            Map.merge(row.record, %{"status" => status, "result" => value, "error" => error})

          row |> Ecto.Changeset.change(record: record) |> Repo.update!()

          {:ok, event} =
            Feed.record_in_transaction(%{
              event: "subject_document",
              agent: row.record["actor"]["id"],
              root_id: definition.id,
              subject: definition.subject,
              request_id: row.request_id,
              path: params["destination"] || params["path"],
              status: status,
              summary: "Document #{params["action"]}: #{status}; no source replacement or commit."
            })

          {record, event}
        end,
        mode: :immediate
      )

    Feed.publish_committed(event)
    result(record)
  end

  defp result(%{"status" => "created"} = record),
    do: {:ok, Map.put(record["result"], "receipt", Map.drop(record, ["request", "result"]))}

  defp result(record), do: {:error, record["error"] || "operation_unconfirmed_do_not_retry_write"}

  defp receipt(definition, access, request_id) do
    case Repo.get(Operation, request_id) do
      %Operation{root_id: id} = row when id == definition.id -> scoped_receipt(row.record, access)
      _unknown -> {:error, "unknown_receipt"}
    end
  end

  defp scoped_receipt(record, access) do
    path = record["request"]["destination"] || record["request"]["path"]
    if includes?(access.read_paths, path), do: {:ok, record}, else: {:error, "path_not_granted"}
  end

  defp decorate(definition, result) do
    result
    |> Map.put("schema_version", "custode.subject_document.v1")
    |> Map.put("root_id", definition.id)
    |> Map.put("subject", definition.subject)
    |> Map.put("source", "current_working_bytes_uncommitted_edits_included")
    |> Map.put("git_revision", nil)
    |> Map.put("read_is_not_write_authority", true)
  end

  defp authorized_root(actor, params) do
    case Enum.find(definitions(), &(&1.id == params["root_id"])) do
      nil -> {:error, "root_not_granted"}
      definition -> authorize_action(definition, grant(actor, definition), params)
    end
  end

  defp authorize_action(_definition, nil, _params), do: {:error, "root_not_granted"}

  defp authorize_action(definition, access, params) do
    action = params["action"]

    if action_allowed?(action, access, params),
      do: {:ok, definition, access},
      else: {:error, "path_or_destination_not_granted"}
  end

  defp action_allowed?(action, access, _params) when action in ~w(browse search),
    do: access.read_paths != []

  defp action_allowed?(action, access, params) when action in @read_actions,
    do: is_nil(params["path"]) or includes?(access.read_paths, params["path"])

  defp action_allowed?("create", access, params),
    do: includes?(access.create_paths, params["path"])

  defp action_allowed?("propose", access, params) do
    includes?(access.propose_paths, params["path"]) and
      includes?(access.read_paths, params["path"]) and
      includes?(access.proposal_destinations, params["destination"])
  end

  defp action_allowed?(_action, _access, _params), do: false

  defp grant(%{kind: :operator}, _definition),
    do: %{
      read_paths: "all",
      create_paths: "all",
      propose_paths: "all",
      proposal_destinations: "all"
    }

  defp grant(actor, definition) do
    entry = Enum.find(definition.grants, &(&1.kind == actor.kind and &1.id == actor.id))

    if entry,
      do: %{
        read_paths: entry[:read_paths] || [],
        create_paths: entry[:create_paths] || [],
        propose_paths: entry[:propose_paths] || [],
        proposal_destinations: entry[:proposal_destinations] || []
      }
  end

  defp includes?("all", _path), do: true
  defp includes?(paths, path) when is_list(paths), do: path in paths
  defp includes?(_paths, _path), do: false

  defp definitions do
    Application.get_env(:custode, :subject_roots, [])
    |> Enum.take(16)
    |> Enum.filter(&valid_definition?/1)
  end

  defp valid_definition?(%{id: id, path: path, subject: subject, grants: grants}),
    do:
      is_binary(id) and id != "" and is_binary(path) and Path.type(path) == :absolute and
        is_binary(subject) and is_list(grants) and Enum.all?(grants, &valid_grant?/1)

  defp valid_definition?(_definition), do: false

  defp valid_grant?(%{kind: kind, id: id} = grant) do
    kind in [:routine, :sub_agent] and is_binary(id) and id != "" and
      Enum.all?(~w(read_paths create_paths propose_paths proposal_destinations)a, fn key ->
        valid_paths?(grant[key] || [])
      end) and
      Enum.all?(~w(create_paths propose_paths proposal_destinations)a, &(grant[&1] != "all"))
  end

  defp valid_grant?(_grant), do: false
  defp valid_paths?("all"), do: true

  defp valid_paths?(paths) when is_list(paths),
    do: length(paths) <= 100 and Enum.all?(paths, &flat_name?/1)

  defp valid_paths?(_paths), do: false

  defp flat_name?(path) when is_binary(path) do
    String.ends_with?(path, ".md") and not String.starts_with?(path, ".") and
      byte_size(path) <= 200 and
      not String.contains?(path, ["/", "\\"]) and not Regex.match?(~r/[\x00-\x1f]/u, path)
  end

  defp flat_name?(_path), do: false

  defp current_identity(%{kind: :operator, id: id}) when is_binary(id) and id != "", do: :ok

  defp current_identity(%{kind: :routine, id: id}) do
    case AgentHandoff.authorization_routine(id) do
      {:ok, _captured} -> :ok
      _unavailable -> {:error, "current_owner_unavailable"}
    end
  end

  defp current_identity(%{kind: :sub_agent, id: id}) do
    case SubAgents.get(id) do
      %{parent: parent} -> current_identity(%{kind: :routine, id: parent})
      nil -> {:error, "current_helper_unavailable"}
    end
  end

  defp current_identity(_actor), do: {:error, "unauthenticated"}

  defp producer(%{kind: :routine, id: id} = actor),
    do: json(%{identity: actor, observed_execution: ExecutionFacts.read(id)})

  defp producer(%{kind: :sub_agent, id: id} = actor) do
    spec = SubAgents.get(id)

    json(%{
      identity: actor,
      parent: spec.parent,
      recorded_session_id: spec.session_id,
      provider: "claude",
      active_turn: nil,
      observation: "spawn_record_not_delivery_proof"
    })
  end

  defp producer(actor), do: json(%{identity: actor, observed_execution: nil})

  @doc false
  def input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => @actions},
        "root_id" => text_schema(160),
        "path" => text_schema(200),
        "destination" => text_schema(200),
        "query" => text_schema(200),
        "request_id" => text_schema(160),
        "content" => %{"type" => "string", "maxLength" => 16_384},
        "expected_revision" => text_schema(64)
      }
    }
  end

  defp text_schema(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}

  defp valid_params(params) when is_map(params) do
    case Basic.validate(params, input_schema()) do
      :ok ->
        required = required(params["action"])

        if Enum.all?(required, &Map.has_key?(params, &1)),
          do: :ok,
          else: {:error, "missing_action_arguments"}

      _invalid ->
        {:error, "invalid_arguments"}
    end
  end

  defp valid_params(_params), do: {:error, "invalid_arguments"}
  defp required("roots"), do: []
  defp required("receipt"), do: ~w(root_id request_id)
  defp required("browse"), do: ~w(root_id)
  defp required("search"), do: ~w(root_id query)
  defp required("create"), do: ~w(root_id path content request_id)
  defp required("propose"), do: ~w(root_id path destination content expected_revision request_id)
  defp required(_read), do: ~w(root_id path)

  @doc "Check current root read authority without touching source content."
  def authorize_root(actor, root_id) do
    with :ok <- current_identity(actor),
         {:ok, _definition, _access} <-
           authorized_root(actor, %{"action" => "browse", "root_id" => root_id}),
         do: :ok
  end

  @doc "Check current document read authority without substituting current bytes for historical content."
  def authorize_read(actor, root_id, path) do
    with :ok <- current_identity(actor),
         {:ok, _definition, _access} <-
           authorized_root(actor, %{"action" => "read", "root_id" => root_id, "path" => path}),
         true <- flat_name?(path) do
      :ok
    else
      false -> {:error, "invalid_path"}
      error -> error
    end
  end

  @doc "Durable operation references, restricted by current root and path read grants."
  def outputs(actor, root_id) do
    with :ok <- current_identity(actor),
         {:ok, definition, access} <-
           authorized_root(actor, %{"action" => "browse", "root_id" => root_id}) do
      rows =
        Repo.all(
          from(row in Operation,
            where: row.root_id == ^definition.id,
            order_by: [desc: fragment("json_extract(?, '$.at')", row.record), asc: row.request_id],
            limit: 100
          )
        )

      records =
        for row <- rows,
            {:ok, record} <- [scoped_receipt(row.record, access)],
            do: Map.put(record, "request_id", row.request_id)

      {:ok, records}
    end
  end

  @doc false
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
