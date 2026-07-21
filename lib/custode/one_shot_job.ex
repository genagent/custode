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
    body =
      (ObanClaude.structured(result) || %{})["summary"] || result.result ||
        "(job produced no text)"

    report(job, """
    One-shot job ##{job.id} (#{tag(job)}) finished.

    Task: #{String.slice(job.args["prompt"], 0, 200)}

    Result: #{body}

    (cost $#{result.cost_usd || 0.0})
    """)

    :ok
  end

  @impl ObanClaude.Worker
  def handle_error(oban_return, payload, %Oban.Job{} = job) do
    kind = if is_struct(payload), do: inspect(payload.kind), else: inspect(oban_return)

    report(job, """
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
end
