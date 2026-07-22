defmodule Custode.OneShotJob do
  @moduledoc """
  A fire-and-forget claude job whose result comes back as a NOTE: on
  completion (success or failure) it writes a markdown file into the
  `report_inbox` directory carried in its args, where the owning agent's next
  sweep files it like any other inbox note. Workspace-files-as-mailboxes --
  no callback machinery, and the parent is never interrupted mid-turn.

  Enqueued by the `run_job` MCP tool; `report_inbox` and `tag` are plain extra
  args keys (`ObanClaude.run/2` ignores unknown keys, so they ride along in
  the stored job args untouched).
  """

  use ObanClaude.Worker, queue: :agents, max_attempts: 1

  @impl ObanClaude.Worker
  def handle_result(result, %Oban.Job{} = job) do
    structured = ObanClaude.structured(result)
    # #120: with a report schema in force, structured carries typed
    # {status, summary, ...} -- prefer those over freeform text, falling back
    # to prose only when the schema was not honored.
    status = (structured || %{})["status"] || "ok"
    body = (structured || %{})["summary"] || result.result || "(job produced no text)"

    report(job, """
    #{front_matter(job, status, result.cost_usd, structured)}
    One-shot job ##{job.id} (#{tag(job)}) finished.

    Task: #{String.slice(job.args["prompt"], 0, 200)}

    Result: #{body}
    """)

    :ok
  end

  # #18: a machine-readable header so the receiving sweep can file the
  # outcome (and any structured payload) mechanically instead of
  # re-judging prose. Fenced JSON: trivially parseable, safely ignorable.
  defp front_matter(job, status, cost_usd, structured) do
    header = %{
      "job" => job.id,
      "tag" => tag(job),
      "status" => status,
      "cost_usd" => cost_usd || 0.0,
      "structured" => structured
    }

    "```json custode-report
" <> Jason.encode!(header) <> "
```
"
  end

  @impl ObanClaude.Worker
  def handle_error(oban_return, payload, %Oban.Job{} = job) do
    kind = if is_struct(payload), do: inspect(payload.kind), else: inspect(oban_return)

    report(job, """
    #{front_matter(job, "failed: " <> kind, failed_cost(payload), nil)}
    One-shot job ##{job.id} (#{tag(job)}) FAILED: #{kind}.

    Task: #{String.slice(job.args["prompt"], 0, 200)}
    """)

    oban_return
  end

  defp report(%Oban.Job{args: %{"report_inbox" => inbox}} = job, text) when is_binary(inbox) do
    if File.dir?(inbox) do
      # through the funnel: a report note wakes the dispatching agent
      # promptly (event kickoff) instead of at its next cron boundary
      {:ok, _path} = Custode.Inbox.drop_path(inbox, "job-#{job.id}-#{tag(job)}.md", text)
    end
  end

  defp report(_job, _text), do: :ok

  defp tag(%Oban.Job{args: args}), do: args["tag"] || "job"

  defp failed_cost(payload) when is_struct(payload), do: ObanClaude.cost_usd(payload)
  defp failed_cost(_payload), do: 0.0
end
