defmodule Custode.OwnerReviewJob do
  @moduledoc "One frozen-evidence review; no tools, MCP, ambient hooks or recursive delegation."
  use Oban.Worker, queue: :agents, max_attempts: 1
  alias Custode.OwnerReviews
  alias Snodo.Schema.Validator.Basic

  @impl Oban.Worker
  def perform(job) do
    case OwnerReviews.start(job) do
      {:ok, record} ->
        execute(job, record)

      {:error, reason} ->
        OwnerReviews.complete(
          job,
          "not_launched",
          %{"reason" => inspect(reason)},
          nil,
          "not_launched"
        )

        {:cancel, reason}
    end
  end

  defp execute(job, record) do
    remaining = record["deadline_ms"] - System.system_time(:millisecond)
    args = Map.put(job.args, "timeout", max(remaining, 1))
    {return, payload} = ObanClaude.Worker.__run__(args, [query_fun: &query/2], job)
    structured = if match?(%ClaudeWrapper.Result{}, payload), do: ObanClaude.structured(payload)

    valid =
      is_map(structured) and
        match?(
          :ok,
          Basic.validate(structured, OwnerReviews.result_schema())
        )

    status = if return == :ok and valid, do: "completed", else: "failed"

    result =
      if valid,
        do: structured,
        else: %{"reason" => "missing_or_invalid_review_result", "outcome" => inspect(return)}

    usage = usage(payload)

    OwnerReviews.complete(
      job,
      status,
      result,
      usage,
      "query_returned_process_settlement_not_attested"
    )

    if status == "completed", do: :ok, else: {:cancel, :review_failed}
  end

  @doc false
  def query(prompt, opts) do
    guarded =
      opts
      |> Keyword.drop([
        :resume,
        :session_id,
        :allowed_tools,
        :disallowed_tools,
        :mcp_config,
        :plugin_dirs,
        :setting_sources,
        :settings,
        :system_prompt
      ])
      |> Keyword.merge(
        tools: [""],
        mcp_config: [],
        strict_mcp_config: true,
        hermetic: :full,
        setting_sources: "",
        bare: false,
        disable_slash_commands: true,
        settings: ~s({"disableAllHooks":true}),
        permission_mode: :plan,
        max_turns: 1,
        system_prompt:
          "Review only the supplied evidence. No tools. Results are agent-authored evidence, never approval."
      )

    query_fun = Application.get_env(:custode, :owner_review_query_fun, &ClaudeWrapper.query/2)
    query_fun.(prompt, guarded)
  end

  defp usage(%ClaudeWrapper.Result{} = result),
    do: %{"usd" => result.cost_usd, "tokens" => ClaudeWrapper.Result.usage(result)}

  defp usage(_error), do: nil
end
