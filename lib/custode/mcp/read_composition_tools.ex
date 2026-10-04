defmodule Custode.MCP.ReadCompositionTools.Read do
  @moduledoc "List or invoke the explicitly activated PR read composition, or inspect its bounded trace."
  use Custode.MCP.Tool, name: "read_composition"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  input_schema(%{
    "type" => "object",
    "required" => ["request"],
    "properties" => %{
      "request" => %{
        "type" => "object",
        "description" =>
          "action list; invoke with name pr_review_context and arguments {repo,number}; trace with trace_id."
      }
    }
  })

  @impl true
  def execute(%{request: request}, frame) do
    request = request |> Jason.encode!() |> Jason.decode!()

    if request["action"] in ~w(list invoke trace) do
      case Custode.ReadCompositions.call(Custode.MCP.caller(frame), request) do
        {:ok, value} -> reply(frame, value)
        {:error, reason} -> fail(frame, "read composition refused: #{inspect(reason)}")
      end
    else
      fail(frame, "read composition requires list, invoke or trace")
    end
  end
end

defmodule Custode.MCP.ReadCompositionTools.Configure do
  @moduledoc "Human-only publish, activate/rollback or disable a PR read composition. Import never activates."
  use Custode.MCP.Tool, name: "read_composition_configure"
  import Custode.MCP.Tools, only: [reply: 2, fail: 2]

  input_schema(%{
    "type" => "object",
    "required" => ["request"],
    "properties" => %{
      "request" => %{
        "type" => "object",
        "description" =>
          "publish with definition {name,repo,description,steps}; activate with name,revision,expected_generation; disable with name,expected_generation."
      }
    }
  })

  @impl true
  def execute(%{request: request}, frame) do
    request = request |> Jason.encode!() |> Jason.decode!()

    if request["action"] in ~w(publish activate disable) do
      case Custode.ReadCompositions.call(Custode.MCP.caller(frame), request) do
        {:ok, value} ->
          reply(frame, value)

        {:error, reason} ->
          fail(frame, "read composition configuration refused: #{inspect(reason)}")
      end
    else
      fail(frame, "configuration requires publish, activate or disable")
    end
  end
end
