defmodule Custode.MCPNumericFieldsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Anubis.Server.{Frame, Handlers}
  alias Custode.CLI.Client
  alias Custode.MCP.NumericSchema

  @budget_tools ~w(
    preview_routine add_routine preview_routine_edit update_routine
    preview_profile define_profile preview_profile_edit update_profile run_job
  )

  setup do
    workspace = tmp_workspace!()
    config_path = Path.join(workspace, "routines.toml")
    system_env!("CUSTODE_CONFIG", config_path)
    system_env!("CUSTODE_MCP_PORT", to_string(Application.fetch_env!(:custode, :mcp_port)))

    tools =
      Custode.MCP.Server
      |> Handlers.get_server_tools(%Frame{})
      |> Enum.filter(&(&1.name in @budget_tools))

    assert length(tools) == length(@budget_tools)

    %{tools: tools, inbox: Path.join(workspace, "inbox"), config_path: config_path}
  end

  test "discovery advertises optional JSON numbers without overlapping unions", %{tools: tools} do
    for tool <- tools, field <- budget_fields(tool.name) do
      property = tool.input_schema["properties"][field]

      assert property["type"] == "number", "#{tool.name}.#{field}"
      refute Map.has_key?(property, "oneOf"), "#{tool.name}.#{field}"
      assert is_binary(property["description"])
      refute field in Map.get(tool.input_schema, "required", [])
    end
  end

  test "normalization preserves metadata, required fields and other numeric constraints" do
    schema = %{
      "required" => ["budget"],
      "properties" => %{
        "budget" => %{
          "description" => "spend cap",
          "oneOf" => [%{"type" => "integer"}, %{"type" => "number"}]
        },
        "count" => %{"type" => "integer"},
        "bounded" => %{
          "oneOf" => [%{"type" => "integer", "minimum" => 0}, %{"type" => "number"}]
        },
        "nullable" => %{"oneOf" => [%{"type" => "number"}, %{"type" => "null"}]}
      }
    }

    expected =
      put_in(schema, ["properties", "budget"], %{
        "description" => "spend cap",
        "type" => "number"
      })

    assert NumericSchema.normalize(schema) == expected
  end

  test "all budget validators accept integers and floats without coercion", ctx do
    for tool <- ctx.tools, field <- budget_fields(tool.name), value <- [10, 10.25] do
      params = Map.put(arguments(tool.name, ctx), field, value)

      assert {:ok, validated} = tool.validate_input.(params)
      assert Map.fetch!(validated, String.to_existing_atom(field)) === value
    end
  end

  test "nonnumeric budgets fail before tool execution", ctx do
    jobs_before = jobs_for("Custode.OneShotJob")

    for tool <- ctx.tools,
        field <- budget_fields(tool.name),
        value <- ["10", true, [], %{}] do
      params = Map.put(arguments(tool.name, ctx), field, value)
      request = %{"params" => %{"name" => tool.name, "arguments" => params}}

      assert {:error, %Anubis.MCP.Error{code: -32_602}, _frame} =
               Handlers.Tools.handle_call(request, %Frame{}, Custode.MCP.Server)
    end

    refute File.exists?(ctx.config_path)
    assert jobs_for("Custode.OneShotJob") == jobs_before
  end

  test "omitted and null optional budgets keep the existing omission behavior", ctx do
    for tool <- ctx.tools do
      params = arguments(tool.name, ctx)
      assert {:ok, _validated} = tool.validate_input.(params)

      for field <- budget_fields(tool.name) do
        assert {:ok, validated} = tool.validate_input.(Map.put(params, field, nil))
        assert Map.get(validated, String.to_existing_atom(field)) == nil
      end
    end

    assert {:ok, %{"toml" => toml}} =
             Client.call("preview_routine", %{"id" => uid("numeric")})

    refute toml =~ "max_budget_usd"
    refute toml =~ "daily_budget_usd"
  end

  test "routine and profile previews preserve both budgets over HTTP", ctx do
    for tool <- ["preview_routine", "preview_profile"],
        {per_turn, daily} <- [{10, 25}, {10.25, 25.5}] do
      params =
        arguments(tool, ctx)
        |> Map.put("max_budget_usd", per_turn)
        |> Map.put("daily_budget_usd", daily)

      assert {:ok, %{"toml" => toml}} = Client.call(tool, params)
      section = if tool == "preview_routine", do: "routines", else: "profiles"
      [entry] = Toml.decode!(toml)[section]

      assert entry["max_budget_usd"] === per_turn
      assert entry["daily_budget_usd"] === daily
    end

    refute File.exists?(ctx.config_path)
  end

  test "run_job accepts numeric HTTP budgets and keeps the default when omitted", ctx do
    for value <- [10, 10.25] do
      params = Map.put(arguments("run_job", ctx), "max_budget_usd", value)
      assert {:ok, %{"job_id" => job_id}} = Client.call("run_job", params)
      job = Custode.Repo.get!(Oban.Job, job_id)
      assert job.args["max_budget_usd"] === value
    end

    assert {:ok, %{"job_id" => job_id}} = Client.call("run_job", arguments("run_job", ctx))
    job = Custode.Repo.get!(Oban.Job, job_id)
    assert job.args["max_budget_usd"] == Application.fetch_env!(:custode, :max_budget_usd)
  end

  test "invalid budgets are protocol errors over HTTP and enqueue nothing", ctx do
    jobs_before = jobs_for("Custode.OneShotJob")

    for tool <- ["preview_routine", "preview_profile", "run_job"],
        value <- ["10", true, [], %{}] do
      params = Map.put(arguments(tool, ctx), "max_budget_usd", value)
      assert {:error, "Invalid params"} = Client.call(tool, params)
    end

    refute File.exists?(ctx.config_path)
    assert jobs_for("Custode.OneShotJob") == jobs_before
  end

  defp budget_fields("run_job"), do: ["max_budget_usd"]
  defp budget_fields(_tool), do: ["max_budget_usd", "daily_budget_usd"]

  defp arguments("run_job", ctx),
    do: %{"prompt" => "count the files", "report_inbox" => ctx.inbox}

  defp arguments(tool, _ctx) do
    key = if String.contains?(tool, "profile"), do: "name", else: "id"
    %{key => uid("numeric")}
  end

  defp system_env!(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)
  end
end
