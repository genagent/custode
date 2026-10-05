defmodule Custode.MCP.ProjectReportDigestTools.Read do
  @moduledoc "Read bounded fleet owner reports, current decisions and report freshness. No dispatch."
  use Custode.MCP.Tool, name: "project_report_digest"
  import Custode.MCP.Tools, only: [fail: 2, reply: 2]

  input_schema(%{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "window_hours" => %{"type" => "integer", "minimum" => 1, "maximum" => 168},
      "project_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
      "report_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 3}
    }
  })

  @impl true
  def execute(params, frame) do
    opts =
      for key <- [:window_hours, :project_limit, :report_limit],
          Map.has_key?(params, key),
          do: {key, params[key]}

    case Custode.ProjectReportDigest.read(get_in(frame.assigns, [:custode_identity]), opts) do
      {:ok, digest} ->
        reply(frame, digest)

      {:error, reason} when is_binary(reason) ->
        fail(frame, reason)

      {:error, _reason} ->
        fail(frame, "Use window_hours 1..168, project_limit 1..50 and report_limit 1..3.")
    end
  end
end
