# scripts/mcp_live.exs -- the agents-driving-agents proof, REAL claude calls
# (several turns, roughly $1-2 total).
#
#   mix run scripts/mcp_live.exs
#
# 1. a beat cold-starts the caretaker (which has mcp: true)
# 2. one prompt asks it to demonstrate both delegation tiers:
#    - run_job: a one-shot inventory job reporting to its OWN inbox
#    - start_agent/prompt_agent/await_agent: a "scribe" sub-agent in a
#      scratch workspace
# 3. a second beat sweeps the job's report note into the journal
#
# The feed at the end shows the whole choreography.

routine = Custode.Routine.default()
workspace = Path.expand(routine.workspace)
inbox = Path.join(workspace, "inbox")

scribe_ws = Path.join(System.tmp_dir!(), "custode_scribe")
File.rm_rf!(scribe_ws)
File.mkdir_p!(scribe_ws)

await! = fn timeout ->
  case ObanClaude.Agent.await(routine.id, [:idle, :awaiting_permission, :waiting_for_user], timeout) do
    {:ok, :idle} -> :ok
    {:ok, other} -> raise "parent settled at #{inspect(other)}"
    {:error, :timeout} -> raise "parent did not settle in #{timeout}ms"
  end
end

IO.puts("== beat 1: cold-start the caretaker ==")
{:ok, _} = Custode.beat()
:ok = await!.(240_000)

IO.puts("\n== the delegation prompt ==")

prompt = """
Demonstrate your delegation tools, then report. Do these in order:

1. Call run_job with prompt "List the markdown files in this directory with a
   one-line description of each.", workspace "#{workspace}", report_inbox
   "#{inbox}", tag "inventory". It is fire-and-forget; do not wait for it.

2. Call start_agent with agent_id "scribe" and workspace "#{scribe_ws}".
   Then prompt_agent scribe with: "Create haiku.md containing one haiku about
   delegating work." Then await_agent scribe with timeout_ms 90000. If scribe
   requests permission for something reasonable, approve it.

3. Finish with directive=none and a one-line summary of what you delegated
   and how the scribe did.
"""

:processing = Custode.ask(prompt)
:ok = await!.(240_000)

IO.puts("\n== beat 2: sweep the job's report note into the journal ==")
# give the fire-and-forget inventory job time to finish and file its note
deadline = System.monotonic_time(:millisecond) + 120_000

Enum.reduce_while(Stream.cycle([:t]), nil, fn _t, _acc ->
  cond do
    Path.wildcard(Path.join(inbox, "job-*.md")) != [] -> {:halt, :ok}
    System.monotonic_time(:millisecond) > deadline -> {:halt, raise("inventory note never landed")}
    true ->
      Process.sleep(1_000)
      {:cont, nil}
  end
end)

{:ok, _} = Custode.beat()
# the beat delivers asynchronously: wait for the sweep to START before
# waiting for it to settle, or the idle-await returns instantly
{:ok, :running} = ObanClaude.Agent.await(routine.id, :running, 60_000)
:ok = await!.(240_000)

IO.puts("\n== results ==\n")
IO.puts("--- feed ---")
Custode.feed(30)

IO.puts("\n--- scribe's artifact (#{scribe_ws}/haiku.md) ---")
IO.puts(File.read!(Path.join(scribe_ws, "haiku.md")))

IO.puts("--- journal.md ---")
IO.puts(File.read!(Path.join(workspace, "journal.md")))

{:ok, info} = ObanClaude.Agent.info(routine.id)
IO.puts("--- parent ledger: turns=#{info.turns} spend=$#{Float.round(info.cost_usd, 4)} ---")

{:ok, scribe_info} = ObanClaude.Agent.info("scribe")
IO.puts("--- scribe ledger: turns=#{scribe_info.turns} spend=$#{Float.round(scribe_info.cost_usd, 4)} ---")
