# scripts/feed_smoke.exs -- exercise the feed OFFLINE (no claude, no cost).
#
#   mix run scripts/feed_smoke.exs
#
# Turn events ride on ObanClaude.run telemetry, so those are driven through
# run/2 with a stubbed :query_fun; the gated/pause events are driven through
# a throwaway agent. Expect two macOS notifications (needs_approval and
# turn_failed).

import ObanClaude.Testing

alias ObanClaude.Agent

File.rm(Custode.Feed.path())

job = %Oban.Job{meta: %{"agent_id" => "feedtest"}}

# a clean turn and a failed turn, through the real run/2 seam
{:ok, _} =
  ObanClaude.run(%{"prompt" => "sweep"},
    job: job,
    query_fun:
      respond(
        structured_result(%{"directive" => "none", "summary" => "filed 2 notes, 1 new TODO"},
          cost_usd: 0.19
        )
      )
  )

{{:cancel, :auth}, _} = ObanClaude.run(%{"prompt" => "sweep"}, job: job, query_fun: fail(:auth))

# the gated states and pause/resume, through a throwaway agent
{:ok, _} = Agent.start_agent("feedtest", enqueue_fun: fn _args, _meta -> {:ok, :fake} end)

:processing = Agent.submit_prompt("feedtest", "cleanup")

:ok =
  Agent.job_finished(
    "feedtest",
    {:ok,
     structured_result(%{
       "directive" => "request_permission",
       "action" => "delete 4 filed notes older than 30 days",
       "summary" => "wants to prune the inbox"
     })}
  )

{:ok, {:awaiting_permission, %{id: action_id}}} =
  Agent.await("feedtest", :awaiting_permission, 2_000)

:rejected = Agent.reject_action("feedtest", action_id, "not in the demo")

:processing = Agent.submit_prompt("feedtest", "ask me something")

:ok =
  Agent.job_finished(
    "feedtest",
    {:ok, structured_result(%{"directive" => "ask_user", "question" => "prune how far back?"})}
  )

{:ok, {:waiting_for_user, _question}} = Agent.await("feedtest", :waiting_for_user, 2_000)

:ok = Agent.emergency_pause("feedtest")
{:ok, :paused} = Agent.await("feedtest", :paused, 2_000)
:resumed = Agent.resume_agent("feedtest")

# let the async notification tasks fire before the VM exits
Process.sleep(300)

IO.puts("\n== Custode.feed() ==")
Custode.feed()

IO.puts("\n== raw feed.jsonl ==")
IO.puts(File.read!(Custode.Feed.path()))
