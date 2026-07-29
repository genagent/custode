defmodule Custode.GitHubIssueAttemptDispatcher do
  @moduledoc false

  alias Custode.{ClaudeAttempts, RepairAttempts, VerificationAttempts, WorkspaceLeases}

  def dispatch(attempt, oban_job_id, options) do
    case value(attempt, :command_kind) do
      "prepare_workspace" ->
        prepare_workspace(attempt, oban_job_id, options)

      "implement" ->
        ClaudeAttempts.dispatch(
          value(attempt, :attempt_id),
          attempt |> value(:dispatch) |> value(:legacy_routine_id),
          options
        )

      "verify" ->
        VerificationAttempts.dispatch(
          value(attempt, :attempt_id),
          attempt |> value(:dispatch) |> value(:legacy_routine_id),
          options
        )

      "repair" ->
        repair(attempt, options)

      _other ->
        {:error, {:unsupported_github_issue_attempt, value(attempt, :command_kind)}}
    end
  end

  defp repair(attempt, options) do
    module =
      case value(attempt, :executor_kind) do
        "model" -> ClaudeAttempts
        "deterministic" -> RepairAttempts
        _other -> nil
      end

    if module do
      module.dispatch(
        value(attempt, :attempt_id),
        attempt |> value(:dispatch) |> value(:legacy_routine_id),
        options
      )
    else
      {:error, :unsupported_repair_executor}
    end
  end

  defp prepare_workspace(attempt, oban_job_id, options) do
    attrs = attempt |> value(:dispatch) |> atomize()

    lease_options =
      [
        oban_job_id: oban_job_id,
        workspace_root: options[:workspace_root],
        artifact_dir: options[:artifact_dir],
        git: options[:git]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case WorkspaceLeases.prepare_attempt(
           value(attempt, :attempt_id),
           attrs,
           lease_options
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end
end
