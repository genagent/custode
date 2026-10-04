defmodule Custode.ReadCompositions do
  @moduledoc "Human-published immutable read definitions, scoped activation and bounded invocation traces."
  import Ecto.Query, only: [from: 2]
  alias Custode.{AgentHandoff, Repo, Repository}
  alias Custode.MCP.{Capabilities, ToolPolicy}
  alias Custode.Operator.Authority
  alias Snodo.Schema.Validator.Basic

  @tools %{
    "repo_view_pr" => Custode.MCP.RepoTools.ViewPr,
    "repo_pr_checks" => Custode.MCP.RepoTools.PrChecks,
    "repo_pr_diff" => Custode.MCP.RepoTools.PrDiff
  }
  @max_bytes 60_000
  @step_bytes 20_000
  @coherence "non_atomic_reads; diff_has_no_head_binding; matching_heads_do_not_prove_snapshot"

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :string, autogenerate: false}
    schema "composition_records" do
      field(:kind, :string)
      field(:name, :string)
      field(:data, :map)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  @doc "The sole opt-in owner. Configuring a name does not publish or activate anything."
  def owner, do: Application.get_env(:custode, :read_composition_owner)

  @doc "Fixed compiled argument contract; references substitute values, never source text."
  def argument_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(repo number),
      "properties" => %{
        "repo" => %{"type" => "string", "maxLength" => 200},
        "number" => %{"type" => "integer", "minimum" => 1, "maximum" => 2_147_483_647}
      }
    }
  end

  @doc "Source template for the initial composition. Publication remains an explicit human operation."
  def template(repo) do
    %{
      "name" => "pr_review_context",
      "repo" => repo,
      "description" => "PR fields, checks and diff, with explicit non-atomic source limits.",
      "steps" =>
        Enum.map(~w(repo_view_pr repo_pr_checks repo_pr_diff), fn tool ->
          %{
            "tool" => tool,
            "arguments" => %{"repo" => %{"$arg" => "repo"}, "number" => %{"$arg" => "number"}}
          }
        end)
    }
  end

  @doc "Shared entry point. Verified transport identity is never a field in a definition or request."
  def call(actor, request) when is_map(request) do
    keys =
      case request["action"] do
        "publish" -> ~w(action definition)
        "activate" -> ~w(action name revision expected_generation)
        "disable" -> ~w(action name expected_generation)
        "list" -> ~w(action)
        "invoke" -> ~w(action name arguments)
        "trace" -> ~w(action trace_id)
        _other -> []
      end

    if Enum.sort(Map.keys(request)) == Enum.sort(keys),
      do: dispatch_request(actor, request),
      else: {:error, :invalid_composition_request}
  end

  def call(_actor, _request), do: {:error, :invalid_composition_request}

  defp dispatch_request(actor, request) do
    case request do
      %{"action" => "publish", "definition" => definition} ->
        publish(actor, definition)

      %{
        "action" => "activate",
        "name" => name,
        "revision" => revision,
        "expected_generation" => expected
      } ->
        activate(actor, name, revision, expected)

      %{"action" => "disable", "name" => name, "expected_generation" => expected} ->
        activate(actor, name, nil, expected)

      %{"action" => "list"} ->
        list(actor)

      %{"action" => "invoke", "name" => name, "arguments" => arguments} ->
        invoke(actor, name, arguments)

      %{"action" => "trace", "trace_id" => id} ->
        trace(actor, id)

      _other ->
        {:error, :invalid_composition_request}
    end
  end

  def publish(actor, source) do
    with :ok <- Authority.human(actor), {:ok, definition} <- validate_definition(source) do
      revision = digest(definition)

      row = %Row{
        id: "definition:" <> revision,
        kind: "definition",
        name: definition["name"],
        data: Map.put(definition, "revision", revision)
      }

      Repo.insert!(row, on_conflict: :nothing)
      {:ok, row.data}
    end
  end

  def activate(actor, name, revision, expected) do
    with :ok <- Authority.human(actor),
         :ok <- valid_name(name),
         true <- is_integer(expected) and expected >= 0,
         {:ok, definition} <- activation_definition(name, revision) do
      Repo.transaction(fn -> activate_record!(name, revision, expected, definition) end,
        mode: :immediate
      )
    else
      false -> {:error, :invalid_generation}
      {:error, _reason} = error -> error
    end
  end

  defp activate_record!(name, revision, expected, definition) do
    current = Repo.get(Row, "activation:" <> name)
    generation = if current, do: current.data["generation"], else: 0
    if generation != expected, do: Repo.rollback(:activation_conflict)

    data = %{
      "name" => name,
      "generation" => generation + 1,
      "revision" => revision,
      "owner_id" => owner(),
      "repo" => definition && definition["repo"]
    }

    save_activation(current, name, data)
    data
  end

  defp save_activation(nil, name, data),
    do: Repo.insert!(%Row{id: "activation:" <> name, name: name, kind: "activation", data: data})

  defp save_activation(current, _name, data),
    do: current |> Ecto.Changeset.change(data: data) |> Repo.update!()

  def list(actor) do
    with :ok <- caller_scope(actor) do
      entries = Repo.all(from(r in Row, where: r.kind == "activation", limit: 10))

      entries = Enum.flat_map(entries, &discover(actor, &1.name))

      {:ok, %{"entries" => entries, "coherence" => @coherence}}
    end
  end

  defp discover(actor, name) do
    with {:ok, activation, definition} <- active(actor, name),
         true <-
           Enum.all?(definition["steps"], &dependency_allowed?(actor, definition, &1["tool"])) do
      [
        Map.take(definition, ~w(name description revision argument_schema))
        |> Map.put("generation", activation["generation"])
      ]
    else
      _other -> []
    end
  end

  def invoke(actor, name, arguments) do
    with {:ok, activation, definition} <- active(actor, name),
         :ok <- validate_arguments(arguments, definition) do
      id = Ecto.UUID.generate()

      data = %{
        "trace_id" => id,
        "actor" => actor_json(actor),
        "name" => name,
        "revision" => definition["revision"],
        "generation" => activation["generation"],
        "repo" => definition["repo"],
        "input_digest" => digest(arguments),
        "status" => "pending",
        "steps" => []
      }

      with {:ok, _row} <- admit_trace(id, name, data) do
        result = dispatch(actor, activation, definition, arguments)
        finish_trace(id, data, result)
      end
    end
  end

  defp admit_trace(id, name, data) do
    Repo.transaction(
      fn ->
        pending =
          Repo.aggregate(
            from(r in Row,
              where:
                r.kind == "trace" and
                  fragment("json_extract(?, '$.status')", r.data) == "pending"
            ),
            :count
          )

        if pending >= 10, do: Repo.rollback(:unconfirmed_invocation_capacity)
        Repo.insert!(%Row{id: "trace:" <> id, kind: "trace", name: name, data: data})
      end,
      mode: :immediate
    )
  end

  def trace(actor, id) when is_binary(id) do
    with :ok <- caller_scope(actor),
         %Row{kind: "trace", data: data} <- Repo.get(Row, "trace:" <> id),
         true <- actor.kind == :operator or data["actor"] == actor_json(actor),
         :ok <- current_repo(actor, data["repo"]) do
      {:ok, data}
    else
      _other -> {:error, :trace_unavailable}
    end
  end

  def trace(_actor, _id), do: {:error, :trace_unavailable}

  defp validate_definition(source) when is_map(source) do
    with true <- Map.keys(source) |> Enum.sort() == ~w(description name repo steps),
         :ok <- valid_name(source["name"]),
         true <- is_binary(source["description"]) and byte_size(source["description"]) <= 1000,
         :ok <- configured_repo(source["repo"]),
         steps when is_list(steps) and length(steps) in 1..3 <- source["steps"],
         true <- Enum.all?(steps, &is_map/1),
         true <- length(Enum.uniq_by(steps, & &1["tool"])) == length(steps),
         true <- Enum.all?(steps, &valid_step?/1) do
      {:ok,
       source
       |> Map.put("owner_id", owner())
       |> Map.put("argument_schema", argument_schema())
       |> Map.put("result_schemas", Map.new(steps, &{&1["tool"], result_schema(&1["tool"])}))
       |> Map.put("dependencies", Map.new(steps, &{&1["tool"], dependency(&1["tool"])}))}
    else
      _other -> {:error, :invalid_definition}
    end
  end

  defp validate_definition(_source), do: {:error, :invalid_definition}

  defp valid_step?(%{"tool" => tool, "arguments" => arguments} = step) do
    Map.keys(step) |> Enum.sort() == ~w(arguments tool) and Map.has_key?(@tools, tool) and
      arguments == %{"repo" => %{"$arg" => "repo"}, "number" => %{"$arg" => "number"}}
  end

  defp valid_step?(_step), do: false
  defp valid_name("pr_review_context"), do: :ok
  defp valid_name(_name), do: {:error, :unknown_composition}

  defp configured_repo(repo) when is_binary(repo) do
    case AgentHandoff.authorization_routine(owner()) do
      {:ok, %{repo: ^repo}} when repo != "" -> :ok
      _other -> {:error, :configured_owner_unavailable}
    end
  end

  defp configured_repo(_repo), do: {:error, :configured_owner_unavailable}

  defp caller_scope(%{kind: :operator}), do: :ok

  defp caller_scope(%{kind: :routine, id: id}) do
    if is_binary(id) and id == owner() do
      case AgentHandoff.authorization_routine(id) do
        {:ok, _routine} -> :ok
        _other -> {:error, :current_owner_unavailable}
      end
    else
      {:error, :composition_not_granted}
    end
  end

  defp caller_scope(_actor), do: {:error, :composition_not_granted}

  defp current_repo(actor, repo) do
    with :ok <- caller_scope(actor),
         :ok <- configured_repo(repo),
         true <- Repository.served?(repo) do
      :ok
    else
      _other -> {:error, :repository_scope_unavailable}
    end
  end

  defp activation_definition(_name, nil), do: {:ok, nil}

  defp activation_definition(name, revision) when is_binary(revision) do
    case Repo.get(Row, "definition:" <> revision) do
      %Row{name: ^name, data: definition} ->
        with :ok <- configured_repo(definition["repo"]),
             true <- definition["owner_id"] == owner() do
          {:ok, definition}
        else
          _other -> {:error, :configured_owner_unavailable}
        end

      _other ->
        {:error, :definition_unavailable}
    end
  end

  defp activation_definition(_name, _revision), do: {:error, :definition_unavailable}

  defp active(actor, name) do
    with :ok <- caller_scope(actor),
         :ok <- valid_name(name),
         %Row{data: %{"revision" => revision} = activation} when is_binary(revision) <-
           Repo.get(Row, "activation:" <> name),
         {:ok, definition} <- activation_definition(name, revision),
         true <- activation["owner_id"] == owner(),
         :ok <- current_repo(actor, definition["repo"]) do
      {:ok, activation, definition}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :composition_disabled}
    end
  end

  defp validate_arguments(arguments, definition) do
    with :ok <- Basic.validate(arguments, argument_schema()),
         true <- arguments["repo"] == definition["repo"] do
      :ok
    else
      _other -> {:error, :invalid_arguments}
    end
  end

  defp dispatch(actor, activation, definition, arguments) do
    Enum.reduce_while(definition["steps"], {%{}, [], "complete", 0}, fn step, acc ->
      execute_step(actor, activation, definition, arguments, step, acc)
    end)
  end

  defp execute_step(actor, activation, definition, arguments, step, {results, traces, _, bytes}) do
    tool = step["tool"]

    with :ok <- reauthorize(actor, activation, definition, tool),
         {:ok, value} <- safe_read(tool, arguments),
         :ok <- validate_result(tool, value),
         encoded <- Jason.encode!(value),
         true <- byte_size(encoded) <= @step_bytes and bytes + byte_size(encoded) <= @max_bytes do
      entry = %{"tool" => tool, "status" => "ok", "bytes" => byte_size(encoded)}

      {:cont,
       {Map.put(results, tool, value), traces ++ [entry], "complete", bytes + byte_size(encoded)}}
    else
      error ->
        reason = stopping_reason(error)
        entry = %{"tool" => tool, "status" => "stopped", "reason" => reason}
        {:halt, {results, traces ++ [entry], reason, bytes}}
    end
  end

  defp reauthorize(actor, activation, definition, tool) do
    with {:ok, current, _definition} <- active(actor, definition["name"]),
         true <- current == activation,
         true <- dependency_allowed?(actor, definition, tool) do
      :ok
    else
      _other -> {:error, :authorization_activation_or_dependency_changed}
    end
  end

  defp dependency_allowed?(actor, definition, tool) do
    names = Capabilities.authorized_tool_names(:main, actor)

    (names == :all or tool in names) and ToolPolicy.fetch(tool) == {:ok, :read} and
      definition["dependencies"][tool] == dependency(tool)
  end

  defp safe_read(tool, arguments) do
    read(tool, arguments)
  rescue
    _error -> {:error, :dependency_read_failed}
  catch
    :exit, _reason -> {:error, :dependency_read_failed}
  end

  defp read("repo_view_pr", args), do: Repository.view_pr(args["repo"], args["number"])
  defp read("repo_pr_checks", args), do: Repository.pr_checks(args["repo"], args["number"])
  defp read("repo_pr_diff", args), do: Repository.pr_diff(args["repo"], args["number"])

  defp validate_result(tool, value) do
    schema = result_schema(tool)
    normalized = value |> Jason.encode!() |> Jason.decode!()

    case Basic.validate(normalized, schema) do
      :ok -> :ok
      _other -> {:error, :invalid_dependency_result}
    end
  end

  defp result_schema(tool) do
    case tool do
      "repo_view_pr" ->
        %{
          "type" => "object",
          "required" => ["number", "head_sha"],
          "properties" => %{
            "number" => %{"type" => "integer"},
            "head_sha" => %{"type" => "string"}
          }
        }

      "repo_pr_checks" ->
        %{
          "type" => "object",
          "required" => ["sha", "checks"],
          "properties" => %{"sha" => %{"type" => "string"}, "checks" => rows_schema()}
        }

      "repo_pr_diff" ->
        %{
          "type" => "object",
          "required" => ["files"],
          "properties" => %{"files" => rows_schema()}
        }
    end
  end

  defp rows_schema, do: %{"type" => "array", "maxItems" => 100, "items" => %{"type" => "object"}}
  defp stopping_reason(false), do: "output_limit"
  defp stopping_reason({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp stopping_reason(_error), do: "dependency_read_failed"

  defp finish_trace(id, data, {results, steps, status, bytes}) do
    data =
      Map.merge(data, %{
        "status" => status,
        "steps" => steps,
        "bytes" => bytes,
        "repo" => Repo.get!(Row, "definition:" <> data["revision"]).data["repo"]
      })

    Repo.transaction(
      fn ->
        Repo.get!(Row, "trace:" <> id) |> Ecto.Changeset.change(data: data) |> Repo.update!()

        old =
          Repo.all(
            from(r in Row,
              where:
                r.kind == "trace" and fragment("json_extract(?, '$.status')", r.data) != "pending",
              order_by: [desc: r.inserted_at],
              limit: 100,
              offset: 100
            )
          )

        Enum.each(old, &Repo.delete!/1)
      end,
      mode: :immediate
    )

    {:ok,
     %{
       "trace_id" => id,
       "revision" => data["revision"],
       "generation" => data["generation"],
       "status" => status,
       "results" => results,
       "coherence" => @coherence
     }}
  end

  defp dependency(tool) do
    modules = [
      Map.fetch!(@tools, tool),
      Repository,
      __MODULE__,
      Application.get_env(:custode, :repo_ops, Custode.Repository.Ops)
    ]

    Enum.each(modules, &Code.ensure_loaded!/1)

    digest(
      {"read_composition.v1", Enum.map(modules, & &1.module_info(:md5)),
       Map.fetch!(@tools, tool).input_schema(), ToolPolicy.fetch(tool)}
    )
  end

  defp actor_json(actor), do: %{"kind" => Atom.to_string(actor.kind), "id" => actor.id}

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
