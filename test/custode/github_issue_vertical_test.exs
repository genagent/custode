defmodule Custode.GitHubIssueVerticalTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ClaudeAttempts,
    ContextBundle,
    ContextBundles,
    GitHubIssueIntake,
    GitHubIssueVertical,
    LegacyRoleBindingProjection,
    Memory,
    Mission,
    MissionTarget,
    Repo,
    RoleBinding,
    RoleBindings,
    SpendLedger,
    WorkEvent,
    WorkItem,
    WorkItems,
    WorkspaceLease,
    WorkspaceLeases
  }

  @repository_id "1307868502"
  @repository "genagent/custode"

  setup do
    cleanup!()
    root = Path.join(System.tmp_dir!(), "custode-vertical-#{Ecto.UUID.generate()}")
    repository = Path.join(root, "repository")
    workspaces = Path.join(root, "workspaces")
    artifacts = Path.join(root, "artifacts")
    notebook = Path.join(root, "notebook")
    File.mkdir_p!(repository)
    File.mkdir_p!(Path.join(notebook, "inbox"))
    init_repository!(repository)

    routine =
      routine_fixture!(notebook, %{
        id: uid("issue-worker"),
        profile: :backlog_worker,
        repo: @repository,
        working_dir: repository,
        model: "sonnet",
        effort: "low",
        max_budget_usd: 1.0,
        daily_budget_usd: 5.0,
        max_turns: 12,
        timeout_ms: 60_000
      })

    mission = insert_mission!()
    {:ok, _binding, _effects} = project_binding(routine, mission)
    Memory.remember(routine.id, "house-style", "No em dashes.")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(root)
    end)

    %{
      root: root,
      repository: repository,
      workspaces: workspaces,
      artifacts: artifacts,
      routine: routine,
      mission: mission
    }
  end

  test "one approved issue reaches verification_ready with reproducible context and evidence",
       fixture do
    work_item = ingest!(fixture)
    assert :ok = dispatch_to_provider!(fixture, work_item)

    [implementation, preparation] =
      work_item.work_item_id
      |> Attempts.list_for_work_item()
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    assert preparation.executor_kind == "deterministic"
    assert preparation.state == "succeeded"
    assert implementation.executor_kind == "model"
    assert implementation.state == "running"
    assert implementation.provider == "claude"

    assert implementation.expected_work_item_version + 1 ==
             WorkItems.get(work_item.work_item_id).version

    assert :ok = ClaudeAttempts.dispatch(implementation.attempt_id, fixture.routine.id)
    assert provider_job_count(implementation.attempt_id) == 1

    job = provider_job!(implementation.attempt_id)
    test_pid = self()

    query_fun = fn prompt, options ->
      send(test_pid, {:provider_args, prompt, options})
      File.mkdir_p!(Path.join(options[:working_dir], "lib"))
      File.write!(Path.join(options[:working_dir], "README.md"), "changed\n")

      File.write!(
        Path.join(options[:working_dir], "lib/new_feature.ex"),
        "defmodule NewFeature do\nend\n"
      )

      {:ok,
       ObanClaude.Testing.structured_result(
         %{"outcome" => "success", "summary" => "implemented the approved issue"},
         result: "done",
         session_id: "session-368",
         cost_usd: 0.42,
         duration_ms: 125,
         num_turns: 3,
         extra: %{
           "usage" => %{
             "input_tokens" => 100,
             "output_tokens" => 40,
             "cache_creation_input_tokens" => 20,
             "cache_read_input_tokens" => 10
           },
           "stop_reason" => "end_turn"
         }
       )}
    end

    assert :ok =
             ClaudeAttempts.perform(job,
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    assert_receive {:provider_args, prompt, provider_options}
    assert prompt =~ implementation.context_digest

    assert provider_options[:working_dir] ==
             WorkspaceLeases.get_for_work_item(work_item.work_item_id).workspace_path

    assert provider_options[:permission_mode] == :accept_edits
    assert provider_options[:allowed_tools] == ~w(Read Glob Grep Edit Write)
    assert "Bash" in provider_options[:disallowed_tools]
    refute Keyword.has_key?(provider_options, :mcp_config)

    finished = Attempts.get(implementation.attempt_id)
    assert finished.state == "succeeded"
    assert finished.provider_continuation == %{"session_id" => "session-368"}
    assert finished.usage["cost_usd"] == 0.42
    assert finished.usage["tokens"]["total"] == 160

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "verification_ready"
    assert ready.active_attempt_id == nil

    artifacts = Artifacts.list_for_work_item(work_item.work_item_id)
    assert Enum.any?(artifacts, &(&1.kind == "provider_result"))
    assert Enum.any?(artifacts, &(&1.kind == "changed_files"))
    assert Enum.any?(artifacts, &(&1.kind == "implementation_diff"))

    diff = Enum.find(artifacts, &(&1.kind == "implementation_diff"))
    changed_files = Enum.find(artifacts, &(&1.kind == "changed_files"))

    assert Jason.decode!(File.read!(changed_files.location)) == [
             "README.md",
             "lib/new_feature.ex"
           ]

    assert File.read!(diff.location) =~ "README.md"
    assert File.read!(diff.location) =~ "lib/new_feature.ex"

    context = ContextBundles.get(finished.context_bundle.context_bundle_id)
    assert {:ok, body} = ContextBundles.body(context)
    assert ContextBundles.digest(body) == context.digest
    assert body["objective"] == work_item.objective
    assert body["acceptance"] == work_item.acceptance_criteria
    assert body["mission"]["mission_id"] == fixture.mission.mission_id
    assert body["role_binding"]["legacy_routine_id"] == fixture.routine.id
    assert body["recipe"]["role_template"]["version"] == finished.recipe_version
    assert body["knowledge"] |> hd() |> get_in(["provenance", "kind"]) == "legacy_memory"
    assert body["issue_snapshot"]["issue"]["number"] == 368
    assert body["workspace_revision"]["expected_base_revision"]
    assert body["capabilities"]["operations"] == []
    assert "success" in body["output_contract"]["properties"]["outcome"]["enum"]

    assert {:ok, {_status, same_context}} =
             ContextBundles.create(work_item.work_item_id, body, artifact_dir: fixture.artifacts)

    assert same_context.id == context.id

    spend =
      Repo.one!(
        from(entry in SpendLedger.Entry,
          where: entry.attempt_id == ^implementation.attempt_id
        )
      )

    assert spend.agent_id == fixture.routine.id
    assert spend.legacy_routine_id == fixture.routine.id
    assert spend.work_item_id == work_item.work_item_id
    assert spend.mission_id == fixture.mission.mission_id
    assert spend.provider == "claude"
    assert spend.model == "sonnet"

    events = WorkItems.list_events(work_item.work_item_id)
    assert hd(events).kind == "work_item.created"
    assert List.last(events).after_phase == "verification_ready"

    assert Enum.any?(
             events,
             &(&1.correlation_id == "github-issue-vertical:#{work_item.work_item_id}")
           )

    assert Enum.any?(
             events,
             &(&1.correlation_id == "claude-attempt:#{implementation.attempt_id}")
           )

    assert Enum.all?(
             Enum.filter(events, &(&1.kind == "work.next_action.completed")),
             &is_binary(&1.causation_id)
           )
  end

  test "duplicate intake delivery schedules one live coordinator", fixture do
    work_item = ingest!(fixture)

    result = %{
      work_item: %{
        work_item_id: work_item.work_item_id,
        state: work_item.state,
        phase: work_item.phase
      }
    }

    assert {:ok, [first]} = GitHubIssueVertical.schedule(fixture.routine, [result])
    assert {:ok, [duplicate]} = GitHubIssueVertical.schedule(fixture.routine, [result])
    assert duplicate.id == first.id

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == "Custode.GitHubIssueVerticalJob"),
             :count
           ) == 1
  end

  test "a crash after provider checkpoint recovers without a second provider call", fixture do
    work_item = fixture |> ingest!() |> tap(&dispatch_to_provider!(fixture, &1))
    implementation = implementation_attempt!(work_item)
    job = provider_job!(implementation.attempt_id)
    test_pid = self()

    query_fun = fn _prompt, options ->
      send(test_pid, :provider_called)
      File.write!(Path.join(options[:working_dir], "checkpoint.txt"), "durable\n")

      {:ok,
       ObanClaude.Testing.structured_result(%{
         "outcome" => "success",
         "summary" => "checkpointed"
       })}
    end

    assert {:error, :simulated_crash} =
             ClaudeAttempts.perform(job,
               query_fun: query_fun,
               artifact_dir: fixture.artifacts,
               after_checkpoint: fn _artifact -> {:error, :simulated_crash} end
             )

    assert_receive :provider_called
    assert Attempts.get(implementation.attempt_id).state == "running"
    checkpoint = Artifacts.get("claude-result:#{implementation.attempt_id}")
    assert checkpoint
    refute Artifacts.get("implementation-diff:#{implementation.attempt_id}")

    checkpoint_body = checkpoint.location |> File.read!() |> Jason.decode!()

    File.write!(
      Path.join(
        fixture.artifacts,
        "implementation-diff:#{implementation.attempt_id}.diff"
      ),
      checkpoint_body["diff"]
    )

    refuting_query = fn _prompt, _options -> flunk("provider was called after checkpoint") end

    assert :ok =
             ClaudeAttempts.perform(job,
               query_fun: refuting_query,
               artifact_dir: fixture.artifacts
             )

    assert Attempts.get(implementation.attempt_id).state == "succeeded"
    assert Artifacts.get("implementation-diff:#{implementation.attempt_id}")
    assert WorkItems.get(work_item.work_item_id).phase == "verification_ready"
  end

  test "transient infrastructure retries the same Attempt and exhaustion waits for policy",
       fixture do
    work_item = fixture |> ingest!() |> tap(&dispatch_to_provider!(fixture, &1))
    implementation = implementation_attempt!(work_item)
    job = provider_job!(implementation.attempt_id)
    query_fun = ObanClaude.Testing.fail(:timeout)

    assert {:error, :timeout} =
             ClaudeAttempts.perform(%{job | attempt: 1, max_attempts: 3},
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    assert Attempts.get(implementation.attempt_id).state == "running"
    refute Artifacts.get("claude-result:#{implementation.attempt_id}")
    assert provider_job_count(implementation.attempt_id) == 1

    assert :ok =
             ClaudeAttempts.perform(%{job | attempt: 3, max_attempts: 3},
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    failed = Attempts.get(implementation.attempt_id)
    assert failed.state == "failed"
    assert failed.error_class == "retryable_infrastructure"

    waiting = WorkItems.get(work_item.work_item_id)
    assert waiting.state == "waiting"
    assert waiting.phase == "implementing"
    assert waiting.waiting_condition["name"] == "provider_retry"
  end

  test "semantic follow-up is partial and blocks without inventing a failed WorkItem", fixture do
    assert_provider_classification(
      fixture,
      %{
        "outcome" => "semantic_follow_up",
        "summary" => "acceptance needs a narrower decision",
        "reason" => "ambiguous behavior"
      },
      "partial",
      "blocked",
      "semantic_follow_up"
    )
  end

  test "a human question becomes a typed external wait", fixture do
    work_item =
      run_structured_outcome(fixture, %{
        "outcome" => "human_question",
        "summary" => "operator input is required",
        "question" => "Which compatibility behavior should win?"
      })

    attempt = implementation_attempt!(work_item)
    assert attempt.state == "blocked"
    assert attempt.error_class == "human_question"

    waiting = WorkItems.get(work_item.work_item_id)
    assert waiting.state == "waiting"
    assert waiting.waiting_condition["name"] == "operator_answer"
    assert waiting.waiting_condition["question"] == "Which compatibility behavior should win?"
  end

  test "a provider block remains an explicit blocked WorkItem", fixture do
    assert_provider_classification(
      fixture,
      %{
        "outcome" => "blocked",
        "summary" => "required source is unavailable",
        "reason" => "missing dependency"
      },
      "blocked",
      "blocked",
      "blocked"
    )
  end

  defp assert_provider_classification(
         fixture,
         structured,
         attempt_state,
         work_state,
         category
       ) do
    work_item = run_structured_outcome(fixture, structured)
    attempt = implementation_attempt!(work_item)
    assert attempt.state == attempt_state
    assert attempt.outcome["classification"] == category

    transitioned = WorkItems.get(work_item.work_item_id)
    assert transitioned.state == work_state
    assert transitioned.phase == "implementing"
    assert transitioned.blocked_reason["code"] == category
  end

  defp run_structured_outcome(fixture, structured) do
    work_item = fixture |> ingest!() |> tap(&dispatch_to_provider!(fixture, &1))
    implementation = implementation_attempt!(work_item)
    job = provider_job!(implementation.attempt_id)

    assert :ok =
             ClaudeAttempts.perform(job,
               query_fun:
                 ObanClaude.Testing.respond(ObanClaude.Testing.structured_result(structured)),
               artifact_dir: fixture.artifacts
             )

    work_item
  end

  defp ingest!(fixture) do
    pilot = %{
      repository_id: @repository_id,
      issue_numbers: [368],
      policy_version: "github-issue-intake-v1"
    }

    issue = %{
      number: 368,
      title: "Compile context and run Claude",
      body: "Implement the bounded provider slice.",
      state: "open",
      labels: ["enhancement"],
      updated_at: "2026-07-29T17:00:00Z",
      url: "https://github.com/genagent/custode/issues/368",
      comments: []
    }

    assert {:ok, result} =
             GitHubIssueIntake.reconcile(
               fixture.mission,
               @repository_id,
               @repository,
               issue,
               pilot: pilot
             )

    WorkItems.get(result.work_item.work_item_id)
  end

  defp dispatch_to_provider!(fixture, work_item) do
    assert :ok =
             GitHubIssueVertical.perform(
               fixture.routine.id,
               work_item.work_item_id,
               oban_job_id: System.unique_integer([:positive]),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )
  end

  defp implementation_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.find(&(&1.executor_kind == "model"))
  end

  defp provider_job!(attempt_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.ClaudeAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp provider_job_count(attempt_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.ClaudeAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp insert_mission! do
    mission =
      %{
        mission_id: "mission-vertical-#{Ecto.UUID.generate()}",
        key: "github:repository:#{@repository_id}:#{Ecto.UUID.generate()}",
        purpose: "Operate #{@repository}",
        lifecycle: "persistent",
        status: "active",
        policy_ref: "policy:repository",
        budget_ref: "budget:routine"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    %{
      mission_id: mission.id,
      kind: "github_repository",
      external_id: @repository_id,
      display_name: @repository
    }
    |> MissionTarget.changeset()
    |> Repo.insert!()

    Repo.preload(mission, :targets)
  end

  defp project_binding(routine, mission) do
    routine
    |> LegacyRoleBindingProjection.observation(mission.mission_id)
    |> RoleBindings.project_legacy()
  end

  defp init_repository!(path) do
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Custode Test"])
    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "README.md"), "base\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "base"])
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp cleanup! do
    Repo.delete_all(
      from(job in Oban.Job,
        where:
          job.worker in [
            "Custode.ClaudeAttemptJob",
            "Custode.GitHubIssueVerticalJob",
            "Custode.WorkCommandJob"
          ]
      )
    )

    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(WorkspaceLease)
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.delete_all(WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Custode.OperationCall)
    Repo.delete_all(Mission)
    Repo.delete_all(Custode.Memory.Entry)
  end
end
