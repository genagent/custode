defmodule Custode.OperationDispatcherTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  alias Custode.{OperationDispatcher, OperationRegistry}
  alias Custode.Operations.Fleet.PauseAgent
  alias ObanClaude.Agent

  test "registry lookup is deterministic and duplicate names are rejected" do
    definition = PauseAgent.definition()

    assert {:error, {:duplicate_operation, "fleet.pause_agent"}} =
             OperationRegistry.new([definition, definition])

    registry = OperationRegistry.default()
    assert {:ok, ^definition} = OperationRegistry.fetch(registry, "fleet.pause_agent")

    assert [
             "fleet.pause_agent",
             "git.publish_branch",
             "github.merge_pr",
             "github.open_pr",
             "mission.archive",
             "mission.create",
             "mission.project_legacy_routine",
             "mission.update",
             "role_binding.create",
             "role_binding.project_legacy_routine",
             "role_binding.update",
             "work.create",
             "work.observe",
             "work.reopen",
             "work.transition"
           ] = Enum.map(OperationRegistry.list(registry), & &1.name)
  end

  test "invalid input never reaches a handler" do
    parent = self()
    definition = definition(handler: fn _arguments, _envelope -> send(parent, :called) end)
    {:ok, registry} = OperationRegistry.new([definition])

    assert {:error, {:validation_failed, [agent_id: :required]}} =
             dispatch(%{}, registry)

    refute_received :called
  end

  test "authorization refuses a non-operator actor" do
    assert {:error, {:denied, :operator_required}} =
             dispatch(%{agent_id: "anything"}, OperationRegistry.default(),
               actor: %{kind: :sub_agent, id: "worker"}
             )
  end

  test "publication operations are system-only and cannot be borrowed by an operator" do
    common = %{
      work_item_id: "work",
      attempt_id: "attempt",
      lease_id: "lease",
      repository: "genagent/custode",
      remote: "origin",
      expected_work_item_version: 1
    }

    git_arguments =
      Map.merge(common, %{
        repository_path: "/tmp/repository",
        workspace_path: "/tmp/workspace",
        branch: "custode/work-1",
        expected_workspace_revision: "sha256:workspace",
        expected_head_revision: "head",
        expected_changed_files: ["README.md"],
        commit_message: "feat: publish work"
      })

    github_arguments =
      Map.merge(common, %{
        expected_head_sha: "head",
        head_branch: "custode/work-1",
        base_branch: "main",
        title: "feat: publish work",
        body: "Closes #1."
      })

    Enum.each(
      [
        {"git.publish_branch", git_arguments},
        {"github.open_pr", github_arguments}
      ],
      fn {operation, arguments} ->
        assert {:error, {:denied, :system_required}} =
                 OperationDispatcher.dispatch(%{
                   operation: operation,
                   arguments: arguments,
                   actor: %{kind: :operator, id: "human"},
                   transport: :cli,
                   mission_id: "mission",
                   work_item_id: "work",
                   attempt_id: "attempt",
                   expected_versions: %{work_item: 1},
                   idempotency_key: "test-#{operation}"
                 })
      end
    )
  end

  test "dry run authorizes and previews without invoking the handler" do
    parent = self()

    definition =
      definition(
        handler: fn _arguments, _envelope -> send(parent, :called) end,
        effect_preview: fn arguments, _envelope -> {:ok, %{would_pause: arguments.agent_id}} end
      )

    {:ok, registry} = OperationRegistry.new([definition])

    assert {:ok, response} = dispatch(%{agent_id: "demo"}, registry, dry_run: true)
    assert response.status == :dry_run
    assert response.effect_preview == %{would_pause: "demo"}
    refute_received :called
  end

  test "handler success preserves actor, transport, correlation, and causation" do
    parent = self()

    definition =
      definition(
        handler: fn arguments, envelope ->
          send(parent, {:context, envelope.actor, envelope.transport})
          {:ok, %{agent_id: arguments.agent_id, state: "paused"}}
        end
      )

    {:ok, registry} = OperationRegistry.new([definition])

    assert {:ok, response} =
             dispatch(%{agent_id: "demo"}, registry,
               correlation_id: "corr-1",
               causation_id: "cause-1"
             )

    assert_received {:context, %{kind: :operator, id: "human"}, :cli}
    assert response.status == :succeeded
    assert response.result == %{agent_id: "demo", state: "paused"}
    assert response.correlation_id == "corr-1"
    assert response.causation_id == "cause-1"
  end

  test "handler failures are transport-neutral" do
    definition = definition(handler: fn _arguments, _envelope -> {:error, :offline} end)
    {:ok, registry} = OperationRegistry.new([definition])

    assert {:error, {:handler_failed, :offline}} =
             dispatch(%{agent_id: "ghost"}, registry)
  end

  test "fleet.pause_agent has today's success and offline refusal behavior" do
    id = start_stub_agent!()

    assert {:ok, %{result: %{agent_id: ^id, state: "paused"}}} =
             dispatch(%{agent_id: id}, OperationRegistry.default())

    assert {:ok, :paused} = Agent.await(id, :paused, 1_000)

    assert {:error, {:handler_failed, _reason}} =
             dispatch(%{agent_id: "ghost"}, OperationRegistry.default())
  end

  defp dispatch(arguments, registry, options \\ []) do
    attrs = %{
      operation: "fleet.pause_agent",
      arguments: arguments,
      actor: Keyword.get(options, :actor, %{kind: :operator, id: "human"}),
      transport: :cli,
      idempotency_key:
        Keyword.get_lazy(options, :idempotency_key, fn ->
          "test-#{System.unique_integer([:positive])}"
        end),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    }

    OperationDispatcher.dispatch(attrs, registry)
  end

  defp definition(overrides) do
    base = PauseAgent.definition()
    struct!(base, overrides)
  end
end
