# scripts/dev_continue.exs -- drive custode-dev to a finished approved
# implementation, robust to wherever it settles. REAL claude calls.
#
#   mix run scripts/dev_continue.exs

id = "custode-dev"
settled = [:idle, :awaiting_permission, :waiting_for_user]

defmodule DevDriver do
  def await!(id, states, timeout) do
    case ObanClaude.Agent.await(id, states, timeout) do
      {:ok, status} -> status
      {:error, :timeout} -> raise "custode-dev did not settle in #{timeout}ms"
    end
  end

  # Settle the agent to :idle, approving up to `rounds` proposals on the way.
  def drive(_id, _settled, 0), do: raise("gate rounds exhausted")

  def drive(id, settled, rounds) do
    case DevDriver.await!(id, settled, 400_000) do
      {:awaiting_permission, %{id: action_id, description: description}} ->
        IO.puts("PROPOSAL: #{description}")
        IO.puts("approving...\n")
        :processing = ObanClaude.Agent.approve_action(id, action_id)
        drive(id, settled, rounds - 1)

      {:waiting_for_user, question} ->
        IO.puts("QUESTION: #{question}")
        IO.puts("answering: finish the feed rotation work in your worktree\n")
        :processing = ObanClaude.Agent.submit_prompt(id, "Finish the feed rotation work in your worktree; keep it minimal.")
        drive(id, settled, rounds - 1)

      :idle ->
        IO.puts("settled :idle")
        :ok

      other ->
        IO.puts("settled at #{inspect(other)}")
        :ok
    end
  end
end

IO.puts("== boot state (gates reconciliation ran at app start) ==")

for note <- Path.wildcard("dev-workspace/inbox/restart-gate-*.md") do
  IO.puts("restart notice: #{Path.basename(note)}")
end

IO.puts("\n== beat ==")
{:ok, _} = Custode.beat(id)
{:ok, :running} = ObanClaude.Agent.await(id, :running, 60_000)
:ok = DevDriver.drive(id, settled, 3)

IO.puts("\n== journal (newest) ==")

for entry <- Custode.Notebook.journal(id, 3) do
  IO.puts("##{entry.id} [#{entry.title}] #{String.slice(entry.body, 0, 160)}")
end

IO.puts("\ndurable today: $#{Float.round(Custode.SpendLedger.today(id), 4)}")
