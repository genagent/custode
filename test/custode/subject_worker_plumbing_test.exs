defmodule Custode.SubjectWorkerPlumbingTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Agents,
    ContextReceipts,
    HelperRecords,
    OperatorMessage,
    OperatorMessages,
    Repo,
    RunContextReceipts,
    SubAgents,
    SubjectAssignmentLaunch,
    SubjectAssignments,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  alias Custode.MCP.{CallContext, Identity, Tools}
  alias Custode.Operator.Actions
  alias Custode.SubjectAssignments.{Assignment, Launch}
  alias Snodo.Client
  @human %{kind: :operator, id: "controlled-worker-human"}

  defmodule Runner do
    @moduledoc false
    @behaviour ClaudeWrapper.Runner

    # This runner never delegates to a CLI. The script exists only in the exact
    # test process performing the real worker; every other invocation refuses.
    @impl true
    def run_observed(_binary, args, _opts, _timeout, _observer) do
      script = Process.delete({__MODULE__, :script}) || raise "missing controlled worker script"
      result = script.(args)

      text = Jason.encode!(%{type: "result", subtype: "success", is_error: false, result: result})
      {:ok, {text <> "\n", 0, ""}}
    end

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("unobserved runner refused")
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: raise("streaming runner refused")
  end

  setup do
    previous = Application.fetch_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, Runner)

    on_exit(fn ->
      case previous do
        {:ok, runner} -> Application.put_env(:claude_wrapper, :runner, runner)
        :error -> Application.delete_env(:claude_wrapper, :runner)
      end
    end)

    parent = routine_fixture!(tmp_workspace!())
    root = tmp_workspace!()
    File.write!(Path.join(root, "preferences.md"), "No car; prefer train access.\n")
    File.write!(Path.join(root, "private.md"), "Unadmitted private source.\n")
    definition = %{id: uid("controlled-subject"), path: root, subject: "Travel", grants: []}
    put_env!(:subject_roots, [definition])
    put_env!(:mcp_config_dir, tmp_workspace!())
    %{parent: parent, root: root, definition: definition}
  end

  for protocol <- ["2025-06-18", "2026-07-28"] do
    @protocol protocol
    test "two actual workers use scoped HTTP documents and survive cleanup on #{@protocol}",
         ctx do
      ctx = Map.put(ctx, :protocol, @protocol)
      first = launch!(ctx, "research.md", ["preferences.md", "research.md"])
      ordinary_refused!(first, ctx)

      execute!(first, fn client ->
        preferences = call!(client, ctx, "read", %{"path" => "preferences.md"})
        assert preferences["content"] == "No car; prefer train access.\n"
        assert preferences["revision"]
        refused!(client, ctx, "read", %{"path" => "private.md"})
        refused!(client, ctx, "create", %{"path" => "preferences.md", "content" => "replace"})
        refused!(client, ctx, "create", %{"path" => "unadmitted.md", "content" => "outside"})

        research =
          "Source: controlled fixture, 2026-10-04.\nUncertainty: train schedules unverified.\n" <>
            "Preference revision: #{preferences["revision"]}\n#{preferences["content"]}"

        output = call!(client, ctx, "create", %{"path" => "research.md", "content" => research})

        assert output["receipt"]["producer"]["assignment_execution"]["launch_id"] ==
                 first.launch.launch_id

        assert output["receipt"]["producer"]["assignment_execution"]["execution"]["job_id"] ==
                 first.job.id

        refused!(client, ctx, "create", %{"path" => "research.md", "content" => "overwrite"})
        Process.put(:first_worker_revision, preferences["revision"])
        "Synthetic worker published #{output["revision"]}"
      end)

      terminal!(first)
      retained_research = File.read!(Path.join(ctx.root, "research.md"))
      assert retained_research =~ "Source: controlled fixture, 2026-10-04"
      assert retained_research =~ "Uncertainty:"
      assert :ok = Agents.stop_agent(first.id)
      SubAgents.forget(first.id)
      File.rm_rf!(first.workspace)
      refute File.exists?(first.workspace)
      assert File.dir?(ctx.root)
      File.write!(Path.join(ctx.root, "preferences.md"), "Human edit: prefer Camogli, no car.\n")

      second = launch!(ctx, "follow-up.md", ["preferences.md", "research.md", "follow-up.md"])
      refute second.id == first.id
      refute second.job.meta["agent_generation"] == first.job.meta["agent_generation"]
      refute second.launch.record["helper_epoch"] == first.launch.record["helper_epoch"]
      ordinary_refused!(second, ctx)

      execute!(second, fn client ->
        current = call!(client, ctx, "read", %{"path" => "preferences.md"})
        assert current["content"] == "Human edit: prefer Camogli, no car.\n"
        refute current["revision"] == Process.get(:first_worker_revision)
        research = call!(client, ctx, "read", %{"path" => "research.md"})
        assert research["content"] == retained_research
        refused!(client, ctx, "create", %{"path" => "research.md", "content" => "replace"})

        content =
          "Source: controlled follow-up, 2026-10-04.\nUncertainty: no native inference.\n" <>
            "Current preferences #{current["revision"]}: #{current["content"]}" <>
            "Retained research #{research["revision"]}: #{research["content"]}"

        output = call!(client, ctx, "create", %{"path" => "follow-up.md", "content" => content})
        assert output["receipt"]["producer"]["identity"]["id"] == second.id
        "Synthetic worker published #{output["revision"]}"
      end)

      terminal!(second)
      assert File.read!(Path.join(ctx.root, "research.md")) == retained_research
      assert File.read!(Path.join(ctx.root, "follow-up.md")) =~ "Human edit: prefer Camogli"
      assert File.read!(Path.join(ctx.root, "private.md")) == "Unadmitted private source.\n"
      assert {:ok, outputs} = SubjectDocuments.outputs(@human, ctx.definition.id)
      assert length(Enum.filter(outputs, &(&1["status"] == "created"))) == 2
      assert Enum.any?(outputs, &(&1["status"] == "refused_or_unconfirmed"))

      for worker <- [first, second] do
        assert {:ok, [context]} = RunContextReceipts.list(@human, worker.id)
        assert context["assignment_execution"]["launch_id"] == worker.launch.launch_id
        assert context["execution"]["job_id"] == worker.job.id
        assert context["provider_received"] == "unknown"
        assert context["model_used"] == "unknown"
        refute context["native_observation"]
        refute context["document_retrievals"]["receipts"] == []

        for ref <- context["document_retrievals"]["receipts"] do
          assert {:ok, payload} = ContextReceipts.read(@human, ref["receipt_id"])
          assert payload["state"] == "server_emitted"
          assert payload["assignment_execution"]["execution"]["job_id"] == worker.job.id
          assert payload["model_received"] == "unknown"
          assert payload["exact_tool_text"]
        end
      end
    end
  end

  defp launch!(ctx, destination, paths) do
    id = uid("controlled-helper")
    workspace = tmp_workspace!()
    frame = %CallContext{assigns: %{custode_identity: %{kind: :routine, id: ctx.parent.id}}}

    assert tool_json(Tools.StartAgent.execute(%{agent_id: id, workspace: workspace}, frame))[
             "state"
           ] == "idle"

    on_exit(fn -> cleanup_helper(id) end)
    {:ok, epoch} = HelperRecords.publication_reference(id)

    params = %{
      "action" => "admit",
      "assignment_id" => uid("controlled-admission"),
      "helper_id" => id,
      "root_id" => ctx.definition.id,
      "expected_root_revision" => SubjectDocuments.digest(ctx.definition),
      "expected_helper_record_id" => epoch.helper_epoch.record_id,
      "read_paths" => paths,
      "destination" => destination,
      "expires_in_seconds" => 600
    }

    assert {:error, "operator_assignment_admission_required"} =
             SubjectAssignments.invoke(%{kind: :routine, id: ctx.parent.id}, params)

    assert {:ok, _} = SubjectAssignments.invoke(@human, params)

    assert {:ok, message, :created} =
             Actions.message_with_receipt(id, "Controlled subject research",
               actor: %{kind: :routine, id: ctx.parent.id},
               idempotency_key: uid("controlled-delivery")
             )

    launch =
      eventually(fn ->
        Repo.one!(from(l in Launch, where: l.assignment_id == ^params["assignment_id"]))
      end)

    job = Repo.get!(Oban.Job, launch.job_id)
    assert job.worker == "ObanClaude.Agent.Job"
    assert job.state == "available"
    assert job.meta["correlation_id"] == message.provider_correlation_id
    assert job.args["mcp_config"] == [launch.config_path]
    assert job.args["strict_mcp_config"] and job.args["hermetic"]

    config =
      launch.config_path |> File.read!() |> Jason.decode!() |> get_in(["mcpServers", "subject"])

    assert config["url"] == Custode.MCP.memory_url()
    token = String.replace_prefix(config["headers"]["Authorization"], "Bearer ", "")

    %{
      id: id,
      workspace: workspace,
      job: job,
      launch: launch,
      config: config,
      token: token,
      message: message,
      protocol: ctx.protocol
    }
  end

  defp cleanup_helper(id) do
    Agents.stop_agent(id)

    assignments =
      Repo.all(from(a in Assignment, where: a.helper_id == ^id, select: a.assignment_id))

    for launch <- Repo.all(from(l in Launch, where: l.assignment_id in ^assignments)) do
      Identity.revoke_assignment(launch.launch_id)
      SubjectAssignmentLaunch.remove_config(launch)
    end

    Repo.delete_all(from(l in Launch, where: l.assignment_id in ^assignments))
    Repo.delete_all(from(a in Assignment, where: a.helper_id == ^id))

    Repo.delete_all(
      from(j in Oban.Job, where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^id)
    )

    Repo.delete_all(from(r in RunContextReceipts.Row, where: r.agent_id == ^id))
    Repo.delete_all(from(r in ContextReceipts.Row, where: r.actor_key == ^("sub_agent:" <> id)))
    Repo.delete_all(from(m in OperatorMessage, where: m.target_agent_id == ^id))
    SubAgents.forget(id)
    SubjectDocumentBridge.reset()
  end

  defp execute!(worker, script) do
    job = worker.job |> Ecto.Changeset.change(state: "executing", attempt: 1) |> Repo.update!()

    Process.put({Runner, :script}, fn args ->
      assert "--strict-mcp-config" in args
      assert worker.launch.config_path in args
      assert "mcp__subject__subject_context" in args
      refute "--resume" in args
      refute "--continue" in args
      stored = Repo.get!(Oban.Job, job.id)
      assert stored.state == "executing"
      assert stored.args == job.args
      assert stored.meta == job.meta
      assert {:ok, actor} = Identity.verify(worker.token)

      assert SubjectDocuments.digest(stored.args) == worker.launch.record["arguments_sha256"]
      assert SubjectDocuments.digest(stored.meta) == worker.launch.record["meta_sha256"]
      assert :ok == SubjectAssignments.authorize(actor)

      config =
        worker.launch.config_path
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["mcpServers", "subject"])

      assert config == worker.config

      assert {:ok, client} =
               Client.connect({:http, config["url"]},
                 protocol: worker.protocol,
                 headers: [{"authorization", config["headers"]["Authorization"]}]
               )

      try do
        assert {:ok, tools} = Client.list_tools(client)
        assert Enum.map(tools, & &1["name"]) == ["subject_context"]
        script.(client)
      after
        Client.close(client)
      end
    end)

    assert :ok = ObanClaude.Agent.Job.perform(job)
    assert Process.get({Runner, :script}) == nil
    assert {:ok, :idle} = Agents.await(worker.id, :idle, 1_000)
    assert OperatorMessages.get(worker.message.message_id).status == "completed"
  after
    Process.delete({Runner, :script})
  end

  defp terminal!(worker) do
    # The real run:stop and owning worker callbacks execute before a test driver
    # marks the durable queue row complete, just as Oban normally does afterward.
    assert Repo.get!(Launch, worker.launch.launch_id).settled
    assert Identity.verify(worker.token) == :error
    refute File.exists?(worker.launch.config_path)
    assert Repo.get!(Oban.Job, worker.job.id).state == "executing"

    Repo.get!(Oban.Job, worker.job.id)
    |> Ecto.Changeset.change(state: "completed")
    |> Repo.update!()
  end

  defp ordinary_refused!(worker, ctx) do
    assert {:ok, token} = Identity.token(:sub_agent, worker.id)
    refute token == worker.token

    assert {:ok, client} =
             Client.connect({:http, Custode.MCP.memory_url()},
               protocol: worker.protocol,
               headers: [{"authorization", "Bearer " <> token}]
             )

    refused!(client, ctx, "read", %{"path" => "preferences.md"})
    refused!(client, ctx, "create", %{"path" => "research.md", "content" => "ordinary rights"})
    assert :ok = Client.close(client)
  end

  defp call!(client, ctx, action, params) do
    assert {:ok, %{"content" => [%{"text" => text}]} = result} =
             Client.call_tool(client, "subject_context", arguments(ctx, action, params))

    refute result["isError"]
    Jason.decode!(text)
  end

  defp refused!(client, ctx, action, params) do
    assert {:ok, %{"isError" => true}} =
             Client.call_tool(client, "subject_context", arguments(ctx, action, params))
  end

  defp arguments(ctx, action, params) do
    Map.merge(params, %{
      "action" => action,
      "root_id" => ctx.definition.id,
      "request_id" => uid("controlled-document")
    })
    |> Map.drop(if action == "create", do: [], else: ["request_id"])
  end
end
