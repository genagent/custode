# Explicit opt-in proof using real provider CLIs. Not part of mix test's default paths.
# CUSTODE_RUN_LIVE_PM_PROOF=1 CUSTODE_TEST_MCP_PORT=6183 mix test scripts/pm_proof_test.exs
unless System.get_env("CUSTODE_RUN_LIVE_PM_PROOF") == "1" do
  raise "set CUSTODE_RUN_LIVE_PM_PROOF=1 to authorize the bounded real-provider proof"
end

defmodule Custode.LiveProjectManagerProof do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Agents, ConversationArcs, Memory, OperatorMessages, PeerMessages, Repo}
  alias Custode.Operator.Actions

  @moduletag timeout: 900_000

  test "real Claude and Codex owners coordinate through the manager" do
    manager = routine("manager", :claude, :caretaker)
    claude = routine("claude", :claude, :assistant)
    codex = routine("codex", :codex, :assistant)
    routines = [manager, claude, codex]
    put_env!(:routines, routines)
    put_env!(:feed_path, nil)
    Enum.each(routines, &Custode.MCP.write_routine_config!(&1.id))

    on_exit(fn ->
      Enum.each(routines, fn routine ->
        Agents.stop_agent(routine.id, routine.provider)
        File.rm(Custode.MCP.config_path(routine.id))
      end)
    end)

    discussion =
      turn!(manager, """
      This is a bounded PM proof on disposable projects #{claude.id} (Claude) and
      #{codex.id} (Codex). Discuss how you would ask each owner to return a one-line
      compatibility finding. This turn is discussion only: do not send peer messages,
      wake anyone, change a schedule, or propose a write. Finish with directive none.
      """)

    assert Repo.aggregate(Custode.PeerMessage, :count) == 0

    dispatch =
      turn!(manager, """
      I authorize exactly one bounded peer request to each of #{claude.id} and #{codex.id}.
      Read project_progress for both, then peer_send each a request to reply with its
      provider name and the literal evidence marker COMPAT-BASE. No filesystem, repository,
      gate, or schedule changes. These peer requests are authorized coordination through
      your granted tools; the recipients must not perform other actions. Record the two
      request IDs and next step in remember under the key pm-proof-plan. The recipients
      use on_note=ignore in this proof, so do not beat them or wait for replies. End now
      with directive none and a summary naming the accepted request IDs.
      """)

    actor = %{kind: :routine, id: manager.id}
    {:ok, requests} = PeerMessages.list(actor, direction: :sent)
    assert length(requests) == 2
    assert Enum.sort(Enum.map(requests, & &1.recipient)) == Enum.sort([claude.id, codex.id])
    assert {:ok, _plan} = Memory.recall(manager.id, "pm-proof-plan")
    drain!(:ticks)

    constraint =
      turn!(claude, """
      This is direct operator input for the compatibility request in your inbox.
      Updated constraint: return COMPAT-CHANGED instead of COMPAT-BASE. Inspect the peer
      request, acknowledge its receipt, then peer_reply with provider Claude, the marker
      COMPAT-CHANGED, and this operator message as evidence. You are authorized to use
      peer_ack/peer_reply and notebook tools; perform no other writes or schedule changes.
      Return directive none. Do not ask for another approval for this bounded reply.
      """)

    codex_result =
      turn!(codex, """
      Read the manager's compatibility request in your inbox, peer_ack it, and peer_reply
      with provider Codex and the literal evidence marker COMPAT-BASE. The evidence is
      this bounded operator request, not a repository inspection. You are authorized to
      use peer_ack/peer_reply and notebook tools; perform no other writes or schedule
      changes. Return directive none without starting any further work.
      """)

    drain!(:ticks)
    {:ok, replies} = PeerMessages.list(actor, direction: :inbox)
    assert length(replies) == 2
    assert Enum.all?(replies, &(&1.reply_to in Enum.map(requests, fn request -> request.id end)))

    for {sender, marker} <- [{claude.id, "COMPAT-CHANGED"}, {codex.id, "COMPAT-BASE"}] do
      reply = Enum.find(replies, &(&1.sender == sender))
      assert reply && reply.body =~ marker
    end

    for request <- requests do
      assert {:ok, received} = PeerMessages.read(actor, request.id)
      assert received.acknowledged_at
    end

    summary =
      turn!(manager, """
      Reconcile the two compatibility requests. Start with fresh project_progress reads
      for #{claude.id} and #{codex.id}, and read your peer replies. The operator changed
      one project's constraint directly. Your final summary must name COMPAT-CHANGED,
      COMPAT-BASE, and the exact direct operator message ID that changed the constraint.
      Explain these are reported markers, not an independently verified code change.
      Update pm-proof-plan with the request/reply/evidence IDs and remaining work. Do not
      send any more peer messages, alter schedules, or approve anything. Directive none.
      """)

    output = Jason.encode!(summary.result)
    assert output =~ "COMPAT-CHANGED"
    assert output =~ "COMPAT-BASE"
    assert output =~ constraint.message_id

    previous_arc = ConversationArcs.read_model(manager.id).current
    assert {:ok, _rotated} = ConversationArcs.rotate(manager.id, previous_arc.logical_id)
    assert :ok = Agents.stop_agent(manager.id, manager.provider)

    recovery =
      turn!(manager, """
      This is a new manager process. Reconstruct pm-proof-plan with recall and read its
      existing peer exchanges. Refresh the two projects' progress. Summarize each reported
      outcome and what remains. Include the exact two original request IDs, the two owner
      reply IDs, and the direct operator message ID that changed a constraint, finding
      them in durable records. Return every ID in full in the final summary, with no
      shortened prefixes: the four peer IDs must be complete hyphenated UUIDs. A long
      one-line summary is acceptable for this check. Do not dispatch requests or change
      schedules. Do not infer success merely from acknowledgment. Directive none.
      """)

    recovered = Jason.encode!(recovery.result)
    assert recovered =~ "COMPAT-CHANGED"
    assert recovered =~ "COMPAT-BASE"

    for id <- Enum.map(requests ++ replies, & &1.id) ++ [constraint.message_id] do
      assert recovered =~ id
    end

    assert ConversationArcs.read_model(manager.id).current.arc_id != previous_arc.arc_id
    assert is_binary(previous_arc.provider_session_id)
    assert is_binary(recovery.provider_session_id)
    assert recovery.provider_session_id != previous_arc.provider_session_id
    assert Repo.aggregate(Custode.PeerMessage, :count) == 4
    assert Enum.all?(routines, &(Custode.Gates.open_gates(&1.id) == []))
    assert Enum.all?(Custode.Routine.all(), &(&1.cron == "@yearly" and &1.on_note == :ignore))

    evidence = %{
      proved_at: DateTime.utc_now(),
      isolation: "test configuration; schedules/queues withheld; disposable workspaces",
      manager_restart:
        "provider process restarted and native arc rotated; durable records retained",
      turns:
        Enum.map([discussion, dispatch, constraint, codex_result, summary, recovery], &receipt/1),
      request_ids: Enum.map(requests, & &1.id),
      reply_ids: Enum.map(replies, & &1.id),
      constraint_message_id: constraint.message_id
    }

    evidence_path = System.get_env("CUSTODE_PM_PROOF_EVIDENCE", "/tmp/custode-pm-proof.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    IO.puts("PM proof evidence: #{evidence_path}")
  end

  defp turn!(routine, prompt) do
    IO.puts("PM proof: #{routine.id} starting a bounded #{routine.provider} turn")

    assert {:ok, accepted, :created} =
             Actions.message_with_receipt(routine.id, prompt,
               actor: %{kind: :operator, id: "pm-proof-human"},
               via: :liveview,
               idempotency_key: uid("proof-input")
             )

    drain!(:agents)

    eventually(fn ->
      message = OperatorMessages.get(accepted.message_id)

      assert message.status == "completed",
             "proof turn #{message.message_id} ended #{message.status}"

      message
    end)
  end

  defp drain!(queue) do
    result = Oban.drain_queue(queue: queue, with_scheduled: true)
    assert result.failure == 0, "proof queue #{queue} had a failed job"
  end

  defp receipt(message),
    do: %{
      id: message.message_id,
      provider: message.provider,
      status: message.status,
      arc_id: message.arc_id,
      provider_session_id: message.provider_session_id
    }

  defp routine(name, provider, role) do
    %{
      id: uid("live-pm-#{name}"),
      provider: provider,
      model:
        if(provider == :claude, do: "sonnet", else: System.get_env("CUSTODE_PROOF_CODEX_MODEL")),
      role: role,
      tags: if(role == :caretaker, do: [:meta], else: []),
      cron: "@yearly",
      prompt: "Bounded project-manager proof. Read only. No autonomous project work.",
      working_dir: tmp_workspace!(),
      workspace: tmp_workspace!(),
      on_note: :ignore,
      max_turns: 20,
      max_budget_usd: 2.0,
      daily_budget_usd: 15.0,
      daily_budget_tokens: 1_000_000,
      timeout_ms: 120_000,
      hermetic: true,
      mcp: true
    }
  end
end
