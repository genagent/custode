defmodule Custode.ProviderJobsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    AgentHandoff,
    ConversationArcs,
    OperatorMessage,
    OperatorMessages,
    ProviderJobs,
    ProviderTickAdmission,
    Repo,
    Routine
  }

  alias Custode.MCP
  alias Custode.MCP.Identity
  alias ObanClaude.Agent.Job, as: ClaudeAgentJob
  alias ObanClaude.Agent.Tick, as: ClaudeAgentTick
  alias ObanCodex.Agent.{Job, Tick}

  setup do
    marker = uid("provider-jobs")

    on_exit(fn ->
      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.test_marker') = ?", j.meta, ^marker)
        )
      )
    end)

    %{marker: marker}
  end

  test "boot queue planning withholds providers and preserves the agents queue options" do
    previous = Application.get_env(:custode, :oban_queues)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:custode, :oban_queues),
        else: Application.put_env(:custode, :oban_queues, previous)
    end)

    Application.put_env(:custode, :oban_queues,
      agents: [limit: 7, paused: true],
      ticks: 2,
      sensors: 3
    )

    assert ProviderJobs.initial_queues() == [sensors: 3]

    assert ProviderJobs.agents_queue_options() == [
             queue: :agents,
             limit: 7,
             paused: true
           ]
  end

  test "active turns survive a missing agent process and exclude terminal jobs", %{marker: marker} do
    agent_id = uid("durable-owner")

    available = insert_turn!(agent_id, marker, :claude, "available")
    executing = insert_turn!(agent_id, marker, :codex, "executing")
    suspended = insert_turn!(agent_id, marker, :claude, "suspended")
    _completed = insert_turn!(agent_id, marker, :claude, "completed")
    _other = insert_turn!(uid("other-owner"), marker, :claude, "executing")

    assert ProviderJobs.active_turn?(agent_id)

    assert Enum.map(ProviderJobs.active_turns(agent_id), & &1.id) == [
             available.id,
             executing.id,
             suspended.id
           ]

    available |> Ecto.Changeset.change(state: "cancelled") |> Repo.update!()
    executing |> Ecto.Changeset.change(state: "completed") |> Repo.update!()
    suspended |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()

    refute ProviderJobs.active_turn?(agent_id)
    assert ProviderJobs.active_turns(agent_id) == []
  end

  test "boot reconciliation cancels every removed provider job and settles its messages", %{
    marker: marker
  } do
    current = routine_fixture!(tmp_workspace!(), %{provider: :claude})
    removed_claude_id = uid("removed-claude")
    removed_codex_id = uid("removed-codex")
    removed_routine = %{current | id: removed_claude_id}

    assert {:ok, _args, removed_tick_arc} =
             ConversationArcs.tick_args(removed_routine, :scheduled,
               arc_id: "removed-routine-tick"
             )

    current_turn = insert_turn!(current.id, marker, :claude, "available")
    current_tick = insert_tick!(current.id, marker, :claude, "current", "available")
    removed_claude = insert_turn!(removed_claude_id, marker, :claude, "retryable")
    removed_codex = insert_turn!(removed_codex_id, marker, :codex, "executing")

    removed_tick =
      insert_tick!(removed_claude_id, marker, :claude, "old", "available", %{
        "arc_id" => removed_tick_arc.arc_id
      })

    ownerless =
      %{"prompt" => "owner missing"}
      |> Oban.Job.new(
        worker: ClaudeAgentJob,
        queue: :agents,
        meta: %{"test_marker" => marker}
      )
      |> Ecto.Changeset.change(state: "available")
      |> Repo.insert!()

    assert {:ok, removed_queued, :created} =
             OperatorMessages.submit(removed_claude_id, "queued while down", [], fn _message ->
               {:ok, :queued}
             end)

    correlated_removed =
      insert_turn!(removed_claude_id, marker, :claude, "available", %{
        "correlation_id" => removed_queued.provider_correlation_id
      })

    assert {:ok, removed_waiting, :created} =
             OperatorMessages.submit(removed_codex_id, "waiting while down", [], fn _message ->
               {:ok, :delivered}
             end)

    removed_waiting
    |> Ecto.Changeset.change(status: "waiting_for_input")
    |> Repo.update!()

    assert {:ok, current_message, :created} =
             OperatorMessages.submit(current.id, "keep current work", [], fn _message ->
               {:ok, :queued}
             end)

    message_ids = [
      removed_queued.message_id,
      removed_waiting.message_id,
      current_message.message_id
    ]

    on_exit(fn ->
      Repo.delete_all(from(m in OperatorMessage, where: m.message_id in ^message_ids))
    end)

    assert :ok = ProviderJobs.reconcile_removed_routines!()

    assert state(current_turn) == "available"
    assert state(current_tick) == "available"
    assert state(removed_claude) == "cancelled"
    assert state(removed_codex) == "cancelled"
    assert state(removed_tick) == "cancelled"
    assert state(correlated_removed) == "cancelled"
    assert state(ownerless) == "cancelled"

    for message <- [removed_queued, removed_waiting] do
      assert %{
               status: "refused",
               delivery: "refused",
               error: %{"kind" => "delivery_refused", "detail" => ":routine_removed"}
             } = OperatorMessages.get(message.message_id)
    end

    assert %{status: "queued", delivery: "queued"} =
             OperatorMessages.get(current_message.message_id)

    assert [arc] = ConversationArcs.history(removed_claude_id, "removed-routine-tick")
    assert arc.state == "completed"
    assert arc.last_outcome == "not_launched"
    assert arc.rotation_reason == "routine_removed"
  end

  test "boot migration cancels configured legacy turns and projects their messages", %{
    marker: marker
  } do
    routine = routine_fixture!(tmp_workspace!(), %{provider: :claude})

    assert {:ok, claude_message, :created} =
             OperatorMessages.submit(routine.id, "legacy claude turn", [], fn _message ->
               {:ok, :delivered}
             end)

    assert {:ok, codex_message, :created} =
             OperatorMessages.submit(routine.id, "legacy codex turn", [], fn _message ->
               {:ok, :delivered}
             end)

    legacy_claude =
      insert_turn!(routine.id, marker, :claude, "available", %{
        "correlation_id" => claude_message.provider_correlation_id
      })

    legacy_codex =
      insert_turn!(routine.id, marker, :codex, "executing", %{
        "correlation_id" => codex_message.provider_correlation_id
      })

    current =
      insert_turn!(routine.id, marker, :claude, "available", %{
        "config_revision" => Routine.execution_revision(routine)
      })

    message_ids = [claude_message.message_id, codex_message.message_id]

    on_exit(fn ->
      Repo.delete_all(from(m in OperatorMessage, where: m.message_id in ^message_ids))
    end)

    assert :ok = ProviderJobs.reconcile_legacy_turns!()
    assert state(legacy_claude) == "cancelled"
    assert state(legacy_codex) == "cancelled"
    assert state(current) == "available"

    for message <- [claude_message, codex_message] do
      assert %{status: "failed", error: %{"kind" => "recovered_job_state"}} =
               OperatorMessages.get(message.message_id)
    end
  end

  test "stale tick fencing cancels old revisions, old providers, and legacy jobs", %{
    marker: marker
  } do
    routine = routine_fixture!(tmp_workspace!(), %{provider: :codex})
    agent_id = routine.id
    delivery_revision = Routine.delivery_revision(routine)

    assert {:ok, _args, stale_revision_arc} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "stale-revision")

    assert {:ok, _args, stale_provider_arc} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "stale-provider")

    assert {:ok, _args, legacy_arc} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "legacy")

    assert {:ok, _args, executing_arc} =
             ConversationArcs.tick_args(routine, :scheduled, arc_id: "executing")

    current = insert_tick!(agent_id, marker, :codex, delivery_revision, "available")

    stale_revision =
      insert_tick!(agent_id, marker, :codex, String.duplicate("b", 64), "scheduled", %{
        "arc_id" => stale_revision_arc.arc_id
      })

    stale_provider =
      insert_tick!(agent_id, marker, :claude, delivery_revision, "available", %{
        "arc_id" => stale_provider_arc.arc_id
      })

    legacy =
      insert_tick!(agent_id, marker, :codex, nil, "retryable", %{
        "arc_id" => legacy_arc.arc_id
      })

    executing =
      insert_tick!(agent_id, marker, :claude, delivery_revision, "executing", %{
        "arc_id" => executing_arc.arc_id
      })

    terminal = insert_tick!(agent_id, marker, :claude, delivery_revision, "completed")
    other = insert_tick!(uid("other-tick"), marker, :claude, delivery_revision, "available")

    assert {:ok, %{cancelled: 3, executing: [%Oban.Job{id: executing_id}]}} =
             ProviderJobs.fence_stale_ticks(agent_id, :codex, delivery_revision)

    assert executing_id == executing.id

    assert state(current) == "available"
    assert state(stale_revision) == "cancelled"
    assert state(stale_provider) == "cancelled"
    assert state(legacy) == "cancelled"
    assert state(executing) == "executing"
    assert state(terminal) == "completed"
    assert state(other) == "available"

    for logical_id <- ["stale-revision", "stale-provider", "legacy"] do
      assert [arc] = ConversationArcs.history(agent_id, logical_id)
      assert arc.state == "completed"
      assert arc.last_outcome == "not_launched"
      assert arc.rotation_reason == "stale_tick"
    end

    assert [arc] = ConversationArcs.history(agent_id, "executing")
    assert arc.state == "active"
  end

  test "a Codex remint composes config handoff, persisted fencing and Tick admission", %{
    marker: marker
  } do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        mcp: true,
        role: :backlog_worker
      })

    :ok = MCP.write_routine_config!(routine.id)
    old_args = Routine.tick_args(routine)
    old_revision = old_args["delivery_revision"]

    persisted =
      old_args
      |> Oban.Job.new(
        worker: Tick,
        queue: :ticks,
        meta: %{"test_marker" => marker}
      )
      |> Ecto.Changeset.change(state: "available")
      |> Repo.insert!()

    _new_token = Identity.mint(:routine, routine.id)
    :ok = MCP.write_routine_config!(routine.id)
    current_revision = Routine.delivery_revision(routine)
    refute current_revision == old_revision

    assert :ok = AgentHandoff.reconcile(routine.id)
    assert state(persisted) == "cancelled"

    deliver = fn -> :delivered end

    assert {:cancel, {:stale_tick, _id}} =
             ProviderTickAdmission.admit(:codex, routine.id, old_revision, deliver)

    assert :delivered =
             ProviderTickAdmission.admit(:codex, routine.id, current_revision, deliver)
  end

  test "boot refresh changes only the Custode authorization in active Codex jobs", %{
    marker: marker
  } do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        mcp: true,
        role: :backlog_worker
      })

    MCP.write_routine_config!(routine.id)
    {:ok, current_token} = Identity.token(:routine, routine.id)

    old_authorization =
      ~s(mcp_servers.custode.http_headers.Authorization="Bearer expired-token")

    expected_authorization =
      "mcp_servers.custode.http_headers.Authorization=" <>
        Jason.encode!("Bearer " <> current_token)

    original_args = %{
      "prompt" => "preserve the captured turn",
      "working_dir" => "/captured/worktree",
      "model" => "captured-model",
      "config_overrides" => [
        ~s(developer_instructions="captured"),
        old_authorization,
        ~s(model_reasoning_effort="high")
      ],
      "output_schema" => "/captured/schema.json"
    }

    active =
      insert_codex_turn!(routine.id, marker, original_args, "available", %{
        "config_revision" => "captured-semantic-revision"
      })

    terminal = insert_codex_turn!(routine.id, marker, original_args, "completed")

    assert :ok = ProviderJobs.refresh_codex_credentials!()

    expected_args = %{
      original_args
      | "config_overrides" => [
          ~s(developer_instructions="captured"),
          expected_authorization,
          ~s(model_reasoning_effort="high")
        ]
    }

    refreshed = Repo.reload!(active)

    assert refreshed.args == expected_args
    assert refreshed.meta["config_revision"] == "captured-semantic-revision"

    assert refreshed.meta["credential_revision"] ==
             current_token
             |> :erlang.term_to_binary([:deterministic])
             |> then(&:crypto.hash(:sha256, &1))
             |> Base.encode16(case: :lower)

    assert Repo.reload!(terminal).args == original_args
  end

  test "credential refresh cancels a removed routine's orphaned job and projects its message",
       %{
         marker: marker
       } do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        mcp: true,
        role: :backlog_worker
      })

    MCP.write_routine_config!(routine.id)

    authorization =
      ~s(mcp_servers.custode.http_headers.Authorization="Bearer expired-token")

    args = %{
      "prompt" => "preserve the captured turn",
      "config_overrides" => [authorization]
    }

    first = insert_codex_turn!(routine.id, marker, args, "available")
    removed_id = uid("removed-routine")

    assert {:ok, message, :created} =
             OperatorMessages.submit(removed_id, "finish old work", [], fn _message ->
               {:ok, :delivered}
             end)

    on_exit(fn ->
      Repo.delete_all(from(m in OperatorMessage, where: m.message_id == ^message.message_id))
    end)

    orphan =
      insert_codex_turn!(removed_id, marker, args, "available", %{
        "correlation_id" => message.provider_correlation_id
      })

    assert :ok = ProviderJobs.refresh_codex_credentials!()

    refute Repo.reload!(first).args == args
    assert state(orphan) == "cancelled"

    assert %{
             status: "refused",
             delivery: "refused",
             error: %{"kind" => "delivery_refused", "detail" => ":routine_removed"}
           } =
             OperatorMessages.get(message.message_id)
  end

  test "credential refresh fails closed for a configured routine without a current token", %{
    marker: marker
  } do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        mcp: true,
        role: :backlog_worker
      })

    MCP.write_routine_config!(routine.id)
    {:ok, token} = Identity.token(:routine, routine.id)
    true = :ets.delete(Identity, token)

    authorization =
      ~s(mcp_servers.custode.http_headers.Authorization="Bearer expired-token")

    args = %{
      "prompt" => "preserve the captured turn",
      "config_overrides" => [authorization]
    }

    job = insert_codex_turn!(routine.id, marker, args, "available")

    assert_raise RuntimeError, ~r/configured routine/, fn ->
      ProviderJobs.refresh_codex_credentials!()
    end

    assert Repo.reload!(job).args == args
    assert state(job) == "available"

    Identity.mint(:routine, routine.id)
  end

  defp insert_turn!(agent_id, marker, provider, state, extra_meta \\ %{}) do
    worker = if provider == :claude, do: ClaudeAgentJob, else: Job

    %{"prompt" => "test"}
    |> Oban.Job.new(
      worker: worker,
      queue: :agents,
      meta:
        Map.merge(
          %{
            "agent_id" => agent_id,
            "agent_generation" => Ecto.UUID.generate(),
            "agent_turn_id" => Ecto.UUID.generate(),
            "test_marker" => marker
          },
          extra_meta
        )
    )
    |> Ecto.Changeset.change(state: state)
    |> Repo.insert!()
  end

  defp insert_tick!(agent_id, marker, provider, delivery_revision, state, extra_args \\ %{}) do
    worker = if provider == :claude, do: ClaudeAgentTick, else: Tick

    %{
      "agent_id" => agent_id,
      "prompt" => "test",
      "start" => %{"args" => %{}}
    }
    |> then(fn args ->
      if delivery_revision,
        do: Map.put(args, "delivery_revision", delivery_revision),
        else: args
    end)
    |> Map.merge(extra_args)
    |> Oban.Job.new(worker: worker, queue: :ticks, meta: %{"test_marker" => marker})
    |> Ecto.Changeset.change(state: state)
    |> Repo.insert!()
  end

  defp insert_codex_turn!(agent_id, marker, args, state, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          "agent_id" => agent_id,
          "agent_generation" => Ecto.UUID.generate(),
          "agent_turn_id" => Ecto.UUID.generate(),
          "test_marker" => marker
        },
        extra_meta
      )

    args
    |> Oban.Job.new(
      worker: Job,
      queue: :agents,
      meta: meta
    )
    |> Ecto.Changeset.change(state: state)
    |> Repo.insert!()
  end

  defp state(job) do
    Repo.one!(from(j in Oban.Job, where: j.id == ^job.id, select: j.state))
  end
end
