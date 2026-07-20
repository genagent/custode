# scripts/dev_live.exs -- custode working on custode, REAL claude calls
# (~3 sonnet sweeps over the repo, roughly $1-2.50; capped at $3/day).
#
#   mix run scripts/dev_live.exs
#
# 1. beat 1: custode-dev cold-starts, files the kickoff note, orients on
#    ROADMAP.md + git history, journals -- proposes nothing (kickoff says so)
# 2. a poke asks for its one proposed improvement -> :awaiting_permission
# 3. the script approves; the continuation runs in the custode-dev git
#    worktree and implements the change there
# 4. proof: the worktree/branch diff, the journal, the spend

id = "custode-dev"
settled = [:idle, :awaiting_permission, :waiting_for_user]

await! = fn timeout ->
  case ObanClaude.Agent.await(id, settled, timeout) do
    {:ok, status} -> status
    {:error, :timeout} -> raise "custode-dev did not settle in #{timeout}ms"
  end
end

IO.puts("== sweep 1: orientation (cold start from the beat) ==")
{:ok, _} = Custode.beat(id)
{:ok, :running} = ObanClaude.Agent.await(id, :running, 60_000)
status = await!.(300_000)
IO.puts("settled at: #{inspect(status, printable_limit: 200)}\n")

IO.puts("== sweep 2: ask for the proposal ==")

:ok =
  ObanClaude.Agent.cast_prompt(
    id,
    "Sweep again now. This time, per your standing orders, make your one " <>
      "small concrete improvement proposal (directive=request_permission)."
  )

{:ok, :running} = ObanClaude.Agent.await(id, :running, 60_000)

case await!.(300_000) do
  {:awaiting_permission, %{id: action_id, description: description}} ->
    IO.puts("PROPOSAL: #{description}")
    IO.puts("approving; the continuation runs in the custode-dev worktree...\n")
    :processing = ObanClaude.Agent.approve_action(id, action_id)
    final = await!.(300_000)
    IO.puts("after implementation, settled at: #{inspect(final, printable_limit: 300)}")

  other ->
    IO.puts("expected a proposal, settled at: #{inspect(other, printable_limit: 300)}")
end

IO.puts("\n== the paper trail ==")
IO.puts("--- journal (notebook rows) ---")

for entry <- Custode.Notebook.journal(id, 10) do
  IO.puts("##{entry.id} [#{entry.title}] #{String.slice(entry.body, 0, 140)}")
end

IO.puts("\n--- memories ---")

for memory <- Custode.Memory.recall(id) do
  IO.puts("#{memory.key}: #{String.slice(memory.value, 0, 100)}")
end

{:ok, info} = ObanClaude.Agent.info(id)
IO.puts("\nledger: turns=#{info.turns} session-spend=$#{Float.round(info.cost_usd, 4)}")
IO.puts("durable today: $#{Float.round(Custode.SpendLedger.today(id), 4)}")

IO.puts("\n--- git worktrees ---")
{out, 0} = System.cmd("git", ["worktree", "list"])
IO.puts(out)

IO.puts("--- branches (custode-dev's work, if any) ---")
{out, 0} = System.cmd("git", ["branch", "--list", "*custode-dev*", "-v"])
IO.puts(out)
