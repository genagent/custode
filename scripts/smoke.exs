# scripts/smoke.exs -- boot-to-first-beat proof, with REAL claude calls.
#
#   mix run scripts/smoke.exs
#
# The app is already started (mix run boots the supervision tree). No agent
# exists yet; the next minute-boundary cron beat must cold-start it and file
# whatever is unfiled in workspace/inbox/.

routine = Custode.Routine.default()
IO.puts("status at boot: #{inspect(ObanClaude.Agent.status(routine.id))}")
IO.puts("waiting up to ~150s for the first cron beat...\n")

wait = fn target, budget_ms ->
  deadline = System.monotonic_time(:millisecond) + budget_ms

  Enum.reduce_while(Stream.cycle([:t]), nil, fn _t, _acc ->
    with {:ok, :idle} <- ObanClaude.Agent.status(routine.id),
         {:ok, %{turns: turns}} when turns >= target <- ObanClaude.Agent.info(routine.id) do
      {:halt, :ok}
    else
      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {:error, :timeout}}
        else
          Process.sleep(1_000)
          {:cont, nil}
        end
    end
  end)
end

:ok = wait.(1, 150_000) || raise "first beat never landed"

Custode.peek()

ws = Path.expand(routine.workspace)
IO.puts("\n--- journal.md ---\n" <> File.read!(Path.join(ws, "journal.md")))
IO.puts("--- TODO.md ---\n" <> File.read!(Path.join(ws, "TODO.md")))

for note <- Path.wildcard(Path.join(ws, "inbox/*.md")) do
  first = note |> File.read!() |> String.split("\n") |> hd()
  IO.puts("inbox/#{Path.basename(note)}: #{first}")
end
