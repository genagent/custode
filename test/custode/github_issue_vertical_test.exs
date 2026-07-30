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
    CodexAttempts,
    ContextBundle,
    ContextBundles,
    GitHubIssueIntake,
    GitHubIssueVertical,
    GitHubMerge,
    LegacyRoleBindingProjection,
    Memory,
    Mission,
    MissionTarget,
    OperationCall,
    PublicationAttempts,
    RepairAttempts,
    Repo,
    Repository,
    RoleBinding,
    RoleBindings,
    SpendLedger,
    VerificationAttempts,
    WorkAttribution,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems,
    WorkspaceLease,
    WorkspaceLeases
  }

  alias Custode.GitHubReview.{Observation, Reconciler}
  alias Custode.Repair.Disposition
  alias Custode.Verification.{CommandSpec, Recipe}

  @repository_id "1307868502"
  @repository "genagent/custode"

  defmodule PublicationRepoOps do
    @behaviour Custode.Repository.OpsBehaviour

    def open_pr(owner, repo, attrs) do
      state = state()
      head_sha = remote_revision!(state.remote, attrs.head)

      pull_request =
        Agent.get_and_update(state.pid, fn data ->
          number = data.next_number

          pull_request = %{
            number: number,
            title: attrs.title,
            state: "open",
            draft: true,
            base: attrs.base,
            base_sha: nil,
            head: attrs.head,
            head_sha: head_sha,
            updated_at: "2026-07-29T20:00:00Z",
            url: "https://github.com/#{owner}/#{repo}/pull/#{number}",
            body: attrs.body
          }

          {pull_request,
           %{data | next_number: number + 1, pull_requests: [pull_request | data.pull_requests]}}
        end)

      send(state.test_pid, {:open_pr, pull_request})

      {:ok,
       %{
         "number" => pull_request.number,
         "html_url" => pull_request.url,
         "head" => %{"ref" => pull_request.head, "sha" => pull_request.head_sha}
       }}
    end

    def list_prs(_owner, _repo, _opts), do: {:ok, Agent.get(state().pid, & &1.pull_requests)}

    def view_pr(_owner, _repo, number) do
      case Enum.find(Agent.get(state().pid, & &1.pull_requests), &(&1.number == number)) do
        nil -> {:error, :not_found}
        pull_request -> {:ok, pull_request}
      end
    end

    def open_issue(_owner, _repo, _attrs), do: {:error, :unsupported}
    def comment(_owner, _repo, _number, _body), do: {:error, :unsupported}
    def ready_pr(_owner, _repo, _number), do: {:error, :unsupported}
    def merge_pr(_owner, _repo, _number), do: {:error, :unsupported}

    def merge_pr_at_head(_owner, _repo, number, head_sha) do
      if hook = Application.get_env(:custode, :publication_before_merge) do
        hook.(number, head_sha)
      end

      pull_request =
        Agent.get_and_update(state().pid, fn data ->
          {current, rest} = Enum.split_with(data.pull_requests, &(&1.number == number))

          case current do
            [%{head_sha: ^head_sha} = pull_request] ->
              merged =
                Map.merge(pull_request, %{
                  state: "closed",
                  merged: true,
                  merged_at: "2026-07-29T22:00:00Z",
                  merge_commit_sha: "merge-#{String.slice(head_sha, 0, 12)}"
                })

              {merged, %{data | pull_requests: [merged | rest]}}

            _other ->
              {nil, data}
          end
        end)

      case pull_request do
        nil ->
          {:error, :head_changed}

        merged ->
          send(state().test_pid, {:merge_pr_at_head, number, head_sha})
          {:ok, %{"merged" => true, "sha" => merged.merge_commit_sha}}
      end
    end

    def list_issues(_owner, _repo, _opts), do: {:ok, []}
    def view_issue(_owner, _repo, _number), do: {:error, :unsupported}
    def pr_checks(_owner, _repo, _number), do: {:ok, %{sha: nil, checks: []}}
    def pr_diff(_owner, _repo, _number), do: {:ok, %{files: []}}

    def review_snapshot(_owner, _repo, number) do
      with snapshot when is_map(snapshot) <-
             Application.get_env(:custode, :publication_review_snapshot),
           pull_request when not is_nil(pull_request) <-
             Enum.find(Agent.get(state().pid, & &1.pull_requests), &(&1.number == number)) do
        send(state().test_pid, {:review_snapshot, number})
        {:ok, Map.put(snapshot, :pull_request, pull_request)}
      else
        nil -> {:error, :unused}
      end
    end

    def review_state(_owner, _repo, _number) do
      Application.get_env(:custode, :publication_review_state, :unreviewed)
    end

    defp state, do: Application.fetch_env!(:custode, :publication_repo_ops_state)

    defp remote_revision!(remote, branch) do
      case System.cmd(
             "git",
             ["--git-dir", remote, "rev-parse", "refs/heads/#{branch}"],
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.trim(output)
        {output, status} -> raise "remote revision failed (#{status}): #{output}"
      end
    end
  end

  defmodule FailingCleanupGit do
    def remove(_repository_path, _workspace_path), do: {:error, :simulated_cleanup_failure}
  end

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
    remote = Path.join(root, "remote.git")
    init_remote!(repository, remote)

    repo_state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{next_number: 398, pull_requests: []} end},
          id: {:publication_repo_state, Ecto.UUID.generate()}
        )
      )

    put_env!(:repo_ops, PublicationRepoOps)

    put_env!(:publication_repo_ops_state, %{
      pid: repo_state,
      remote: remote,
      test_pid: self()
    })

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

    assert :ok = Repository.ensure_served(@repository, routine.id)

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
      remote: remote,
      repo_state: repo_state,
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
    provider_result = Enum.find(artifacts, &(&1.kind == "provider_result"))
    provider_evidence = provider_result.location |> File.read!() |> Jason.decode!()

    assert provider_evidence["executor"]["protocol_version"] == "custode.executor.v1"
    assert provider_evidence["provider"]["kind"] == "result"

    assert provider_evidence["transcript_refs"] == [
             %{"id" => "session-368", "kind" => "provider_session"}
           ]

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

  test "an operator-selected Codex WorkItem executes through the worker pool", fixture do
    work_item = ingest!(fixture)

    assert :ok =
             dispatch_to_provider!(fixture, work_item,
               executor_provider: "codex",
               executor_selection: %{model: "gpt-5.6-codex"}
             )

    implementation = implementation_attempt!(work_item)
    assert implementation.provider == "codex"
    assert implementation.profile == "gpt-5.6-codex"
    assert implementation.provenance["executor_selection"] == %{"model" => "gpt-5.6-codex"}

    job = provider_job!(implementation.attempt_id)
    assert job.worker == "Custode.CodexAttemptJob"
    assert :ok = CodexAttempts.dispatch(implementation.attempt_id, fixture.routine.id)
    assert provider_job_count(implementation.attempt_id) == 1
    test_pid = self()

    query_fun = fn prompt, options ->
      send(test_pid, {:codex_provider_args, prompt, options})
      File.write!(Path.join(options[:working_dir], "README.md"), "implemented by codex\n")

      {:ok,
       ObanCodex.Testing.structured_result(
         %{"outcome" => "success", "summary" => "Codex completed the bounded WorkItem"},
         session_id: "codex-thread-378",
         usage: %{
           "input_tokens" => 120,
           "cached_input_tokens" => 20,
           "output_tokens" => 35
         }
       )}
    end

    assert :ok =
             CodexAttempts.perform(job,
               query_fun: query_fun,
               artifact_dir: fixture.artifacts,
               output_schema_dir: Path.join(fixture.root, "schemas")
             )

    assert_receive {:codex_provider_args, prompt, provider_options}
    assert prompt =~ implementation.context_digest
    assert provider_options[:sandbox] == :workspace_write
    assert provider_options[:approval_policy] == :never
    assert provider_options[:search] == :disabled
    assert "sandbox_workspace_write.network_access=false" in provider_options[:config_overrides]

    finished = Attempts.get(implementation.attempt_id)
    assert finished.state == "succeeded"
    assert finished.provider_continuation == %{"session_id" => "codex-thread-378"}
    assert finished.usage["cost_usd"] == nil
    assert finished.usage["num_turns"] == 1
    assert finished.usage["tokens"]["input_tokens"] == 120

    assert %Artifact{kind: "provider_result"} =
             Artifacts.get("codex-result:#{implementation.attempt_id}")

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "verification_ready"

    assert {:ok, summary} = WorkAttribution.attempt_summary(implementation.attempt_id)
    assert summary.provider == "codex"
    assert summary.usage.reconciliation.status == "reconciled"
    assert summary.usage.physical_charges.cost_usd == 0.0
    assert summary.usage.logical_attempt_usage.input_tokens == 120
    assert summary.usage.logical_attempt_usage.output_tokens == 35

    spend =
      Repo.one!(
        from(entry in SpendLedger.Entry,
          where: entry.attempt_id == ^implementation.attempt_id
        )
      )

    assert spend.provider == "codex"
    assert spend.model == "gpt-5.6-codex"
    assert spend.input_tokens == 120
    assert spend.output_tokens == 35
    assert spend.cache_read_tokens == 20
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

  test "successful deterministic verification advances to publication_ready with exact evidence",
       fixture do
    work_item = implement_successfully!(fixture)

    assert coordinator_job!(work_item.work_item_id).args == %{
             "routine_id" => fixture.routine.id,
             "work_item_id" => work_item.work_item_id
           }

    assert :ok = dispatch_to_verifier!(fixture, work_item)

    verification = verification_attempt!(work_item)
    implementation = implementation_attempt!(work_item)

    assert verification.state == "running"
    assert verification.executor_kind == "deterministic"
    assert verification.provider == "custode"
    assert verification.caused_by_attempt.attempt_id == implementation.attempt_id
    assert verification_job_count(verification.attempt_id) == 1

    assert :ok =
             VerificationAttempts.dispatch(verification.attempt_id, fixture.routine.id)

    assert verification_job_count(verification.attempt_id) == 1

    assert :ok =
             VerificationAttempts.perform(
               verification_job!(verification.attempt_id),
               artifact_dir: fixture.artifacts
             )

    finished = Attempts.get(verification.attempt_id)
    assert finished.state == "succeeded"
    assert finished.outcome["classification"] == "pass"
    assert Enum.map(finished.outcome["results"], & &1["name"]) == ~w(format test analysis repo)
    assert Enum.all?(finished.outcome["results"], &(&1["status"] == "pass"))

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "publication_ready"
    assert ready.active_attempt_id == nil

    assert {:ok, body} = ContextBundles.body(finished.context_bundle)
    recipe = body["recipe"]["verification"]
    assert Recipe.new(recipe) == {:ok, test_recipe()}
    assert body["recipe"]["verification_authority"] == "internal_override"
    assert recipe["digest"] == finished.provenance["verification_recipe_digest"]

    assert body["workspace_revision"]["revision"] ==
             finished.outcome["workspace_revision"]["revision"]

    artifacts = Artifacts.list_for_work_item(work_item.work_item_id)
    command_results = Enum.filter(artifacts, &(&1.kind == "verification_command_result"))
    assert length(command_results) == 4
    assert Enum.any?(artifacts, &(&1.kind == "verification_manifest"))
    refute Enum.any?(artifacts, &(&1.kind == "verification_failure"))

    events = WorkItems.list_events(work_item.work_item_id)

    assert Enum.any?(
             events,
             &(&1.correlation_id == "verification-attempt:#{verification.attempt_id}")
           )

    refuting_runner = fn _spec, _path, _options ->
      flunk("a terminal verification Attempt executed again")
    end

    assert :ok =
             VerificationAttempts.perform(
               verification_job!(verification.attempt_id),
               runner: refuting_runner,
               artifact_dir: fixture.artifacts
             )
  end

  test "verified work publishes once and waits durably on the draft pull request", fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)

    assert publication.state == "running"
    assert publication.executor_kind == "deterministic"
    assert publication.provider == "custode"
    assert publication_job_count(publication.attempt_id) == 1

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    assert Attempts.get(publication.attempt_id).error_details == nil
    assert_receive {:open_pr, pull_request}
    assert pull_request.draft
    assert pull_request.title == "feat: compile context and run Claude"

    finished = Attempts.get(publication.attempt_id)
    assert finished.state == "succeeded"
    assert finished.outcome["classification"] == "published"
    assert length(finished.outcome["operation_call_ids"]) == 2

    waiting = WorkItems.get(work_item.work_item_id)
    assert waiting.state == "waiting"
    assert waiting.phase == "awaiting_review"
    assert waiting.active_attempt_id == nil
    assert waiting.waiting_condition["name"] == "github_pull_request"
    assert waiting.waiting_condition["head_sha"] == pull_request.head_sha

    operation_calls =
      Repo.all(
        from(call in OperationCall,
          where: call.attempt_id == ^publication.attempt_id,
          order_by: [asc: call.inserted_at]
        )
      )

    assert Enum.map(operation_calls, & &1.operation) ==
             ["git.publish_branch", "github.open_pr"]

    assert Enum.all?(operation_calls, &(&1.status == "succeeded"))
    assert Enum.all?(operation_calls, &(&1.actor["kind"] == "system"))
    assert Enum.all?(operation_calls, &(&1.transport == "worker"))

    artifacts = Artifacts.list_for_work_item(work_item.work_item_id)
    assert Enum.any?(artifacts, &(&1.kind == "branch"))
    assert Enum.any?(artifacts, &(&1.kind == "commit"))
    assert Enum.any?(artifacts, &(&1.kind == "pull_request"))

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    refute_receive {:open_pr, _pull_request}, 50
    assert publication_attempt_count(work_item) == 1
    assert Agent.get(fixture.repo_state, &length(&1.pull_requests)) == 1
  end

  test "a periodic review snapshot records a durable no-op and replays exactly", fixture do
    {waiting, pull_request} = publish_successfully!(fixture)
    pull_request_number = pull_request.number
    attempt_count = waiting.work_item_id |> Attempts.list_for_work_item() |> length()

    put_env!(:publication_review_snapshot, %{
      reviews: [],
      comments: [],
      checks: [
        %{
          id: 9_001,
          name: "test",
          status: "completed",
          conclusion: "success",
          completed_at: "2026-07-29T21:00:00Z"
        }
      ]
    })

    assert {:ok, first} =
             Reconciler.reconcile(
               waiting.work_item_id,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert_receive {:review_snapshot, ^pull_request_number}
    assert first.status == :waiting
    refute first.replayed

    observed = WorkItems.get(waiting.work_item_id)
    assert observed.state == "waiting"
    assert observed.phase == "awaiting_review"
    assert observed.version == waiting.version + 1

    assert {:ok, replay} =
             Reconciler.reconcile(
               waiting.work_item_id,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert replay.replayed
    assert WorkItems.get(waiting.work_item_id).version == observed.version
    assert waiting.work_item_id |> Attempts.list_for_work_item() |> length() == attempt_count

    [artifact] =
      waiting.work_item_id
      |> Artifacts.list_for_work_item()
      |> Enum.filter(&(&1.kind == "github_observation"))

    assert artifact.provenance["accepted"]

    event =
      waiting.work_item_id
      |> WorkItems.list_events()
      |> Enum.find(&(&1.kind == "work_item.observed"))

    assert get_in(event.evidence, ["github_observation", "artifact_id"]) ==
             artifact.artifact_id
  end

  test "a clean pinned review requires approval, merges once, completes, and cleans up",
       fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)
    workspace = publication_workspace!(waiting)

    assert gate.status == "open"
    assert gate.operation == "github.merge_pr"
    assert gate.arguments["expected_head_sha"] == pull_request.head_sha
    assert gate.arguments["expected_version"] == waiting.version + 1
    assert gate.external_preconditions["review_state"]["status"] == "approved"
    refute_receive {:merge_pr_at_head, _number, _head}, 50

    assert {:ok, approved, response} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "maintainer"},
               transport: :cli
             )

    assert approved.status == "approved", inspect(%{gate: approved, response: response})
    assert response.status == :succeeded
    assert approved.operation_call_id == response.call_id
    assert_receive {:merge_pr_at_head, number, head_sha}
    assert number == pull_request.number
    assert head_sha == pull_request.head_sha

    landed = WorkItems.get(waiting.work_item_id)
    assert landed.state == "completed"
    assert landed.phase == "landed"
    assert landed.outcome["head_sha"] == pull_request.head_sha
    assert landed.outcome["merge_commit_sha"] == response.result.pull_request.merge_commit_sha

    lease = WorkspaceLeases.get(gate.arguments["lease_id"])
    assert lease.state == "released"
    refute File.exists?(workspace)

    merge_call = Repo.get_by!(OperationCall, call_id: response.call_id)
    assert merge_call.correlation_id == gate.correlation_id
    assert merge_call.causation_id == gate.causation_id

    completion =
      waiting.work_item_id
      |> WorkItems.list_events()
      |> Enum.find(fn event -> event.after_phase == "landed" end)

    assert completion.correlation_id == gate.correlation_id
    assert completion.causation_id == response.call_id
    assert get_in(completion.evidence, ["acceptance", "gate_id"]) == gate.gate_id

    assert {:error, {:gate_already_resolved, "approved"}} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "maintainer"},
               transport: :cli
             )

    refute_receive {:merge_pr_at_head, _number, _head}, 50

    assert Enum.count(WorkItems.list_events(waiting.work_item_id), &(&1.after_phase == "landed")) ==
             1
  end

  test "a changed head makes the exact merge Gate stale", fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)

    update_pull_request!(fixture, pull_request.number, %{
      head_sha: "advanced-head",
      updated_at: "2026-07-29T21:11:00Z"
    })

    assert_stale_merge_gate!(waiting, gate)
  end

  test "a changed policy makes the exact merge Gate stale", fixture do
    {waiting, _pull_request, gate} = prepare_merge_gate!(fixture)

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^waiting.id),
      set: [policy_ref: "policy:changed"]
    )

    assert_stale_merge_gate!(waiting, gate)
  end

  test "a failed check makes the exact merge Gate stale", fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)
    put_env!(:publication_review_snapshot, failed_merge_snapshot(pull_request))
    assert_stale_merge_gate!(waiting, gate)
  end

  test "a resolver without the operator grant makes the exact merge Gate stale", fixture do
    {waiting, _pull_request, gate} = prepare_merge_gate!(fixture)

    assert {:error, {:stale, changes, stale_gate}} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :sub_agent, id: "unauthorized"},
               transport: :cli
             )

    assert Map.has_key?(changes, "grant_decision")
    assert stale_gate.status == "stale"
    refute_receive {:merge_pr_at_head, _number, _head}, 50
    assert WorkItems.get(waiting.work_item_id).phase == "merge_ready"
  end

  test "a head race at the merge API refuses without activating or merging work", fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)

    put_env!(:publication_before_merge, fn number, _expected_head ->
      update_pull_request!(fixture, number, %{
        head_sha: "raced-head",
        updated_at: "2026-07-29T21:12:00Z"
      })
    end)

    assert {:error, {:stale, changes, stale_gate}} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "maintainer"},
               transport: :cli
             )

    assert Map.has_key?(changes, "operation_precondition")
    assert stale_gate.status == "stale"
    refute_receive {:merge_pr_at_head, _number, _head}, 50

    unchanged = WorkItems.get(waiting.work_item_id)
    assert unchanged.state == "waiting"
    assert unchanged.phase == "merge_ready"

    call = Repo.get_by!(OperationCall, call_id: stale_gate.operation_call_id)
    assert call.status == "stale"
    assert pull_request.head_sha != "raced-head"
  end

  test "a crash before the external merge resumes the same call and merges once", fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)
    crashed = insert_running_merge_call!(gate)

    assert {:ok, approved, response} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "recovery-operator"},
               transport: :cli
             )

    assert approved.operation_call_id == crashed.call_id
    assert response.call_id == crashed.call_id
    assert_receive {:merge_pr_at_head, number, head}
    assert {number, head} == {pull_request.number, pull_request.head_sha}
    assert WorkItems.get(waiting.work_item_id).phase == "landed"
  end

  test "a crash after GitHub merged reconciles completion without merging twice", fixture do
    {waiting, pull_request, gate} = prepare_merge_gate!(fixture)
    crashed = insert_running_merge_call!(gate)
    merge_commit_sha = "already-merged-commit"

    update_pull_request!(fixture, pull_request.number, %{
      state: "closed",
      merged: true,
      merged_at: "2026-07-29T21:13:00Z",
      merge_commit_sha: merge_commit_sha,
      updated_at: "2026-07-29T21:13:00Z"
    })

    assert {:ok, approved, response} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "recovery-operator"},
               transport: :cli
             )

    assert approved.operation_call_id == crashed.call_id
    assert response.call_id == crashed.call_id
    assert response.replayed
    assert response.result, inspect(response)
    assert response.result.pull_request.source == "reconciled"
    assert response.result.pull_request.merge_commit_sha == merge_commit_sha
    refute_receive {:merge_pr_at_head, _number, _head}, 50

    landed = WorkItems.get(waiting.work_item_id)
    assert landed.state == "completed"
    assert landed.phase == "landed"
    assert landed.outcome["merge_commit_sha"] == merge_commit_sha
  end

  test "cleanup failure preserves landed work and records the retained obligation", fixture do
    {waiting, _pull_request, gate} = prepare_merge_gate!(fixture)
    workspace = publication_workspace!(waiting)
    put_env!(:github_merge_workspace_git, FailingCleanupGit)

    assert {:ok, approved, response} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "maintainer"},
               transport: :cli
             )

    assert approved.status == "approved"
    assert response.status == :succeeded
    assert response.result.cleanup.status == "failed"
    assert response.result.cleanup.error =~ "simulated_cleanup_failure"

    landed = WorkItems.get(waiting.work_item_id)
    assert landed.state == "completed"
    assert landed.phase == "landed"

    lease = WorkspaceLeases.get(gate.arguments["lease_id"])
    assert lease.state == "cleanup_failed"
    assert File.dir?(workspace)

    assert Enum.any?(
             response.effects,
             &(&1.type == "workspace_cleanup_failed" and &1.lease_id == lease.lease_id)
           )
  end

  test "requested changes create one semantic repair with exact observation provenance",
       fixture do
    {waiting, pull_request} = publish_successfully!(fixture)

    observation =
      review_observation(waiting, %{
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:05:00Z",
        reviews: [
          %{
            id: 9_002,
            state: "CHANGES_REQUESTED",
            body: "Please cover the stale-head case.",
            commit_id: pull_request.head_sha,
            submitted_at: "2026-07-29T21:05:00Z"
          }
        ]
      })

    assert {:ok, first} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts,
               correlation_id: "github-review:test-correlation",
               causation_id: "github-review:test-causation"
             )

    assert first.status == :repair_ready
    ready_version = WorkItems.get(waiting.work_item_id).version

    assert {:ok, duplicate} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert duplicate.replayed
    assert WorkItems.get(waiting.work_item_id).version == ready_version

    event = latest_transition_event(waiting)
    assert event.correlation_id == "github-review:test-correlation"
    assert event.causation_id == "github-review:test-causation"

    assert :ok = plan_review_repair!(fixture, waiting)
    repair = repair_attempt!(waiting)

    assert repair.executor_kind == "model"
    assert repair.provider == "claude"
    assert repair.caused_by_attempt.attempt_id == publication_attempt!(waiting).attempt_id
    assert repair.provenance["repair_origin"] == "github_review"
    assert repair.provenance["repair_path"] == "semantic_repair"
    assert repair.provenance["active_phase"] == "handling_feedback"
    assert repair.provenance["observation_artifact_id"] == first.artifact.artifact_id

    assert repair.provenance["observation_external_identity"] ==
             first.observation.external_identity

    assert repair.provenance["observation_head_sha"] == pull_request.head_sha
    assert provider_job_count(repair.attempt_id) == 1

    assert {:ok, third} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert third.replayed
    assert repair_attempt_count(waiting) == 1
    assert provider_job_count(repair.attempt_id) == 1
  end

  test "a combined snapshot recovers scheduling after its durable transition", fixture do
    {waiting, pull_request} = publish_successfully!(fixture)

    successful_check =
      review_observation(waiting, %{
        kind: "check_run",
        external_updated_at: "2026-07-29T21:07:00Z",
        checks: [
          %{
            id: 9_020,
            name: "test",
            status: "completed",
            conclusion: "success",
            completed_at: "2026-07-29T21:07:00Z"
          }
        ]
      })

    assert {:ok, %{status: :waiting}} =
             Reconciler.ingest(
               waiting.work_item_id,
               successful_check,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    combined =
      review_observation(WorkItems.get(waiting.work_item_id), %{
        kind: "snapshot",
        external_updated_at: "2026-07-29T21:08:00Z",
        checks: successful_check.checks,
        reviews: [
          %{
            id: 9_021,
            state: "CHANGES_REQUESTED",
            body: "Please address the boundary.",
            commit_id: pull_request.head_sha,
            submitted_at: "2026-07-29T21:08:00Z"
          }
        ]
      })

    refusing_enqueue = fn _job -> {:error, :queue_unavailable} end

    assert {:error, {:review_repair_enqueue_failed, :queue_unavailable}} =
             Reconciler.ingest(
               waiting.work_item_id,
               combined,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts,
               enqueue_fun: refusing_enqueue
             )

    transitioned = WorkItems.get(waiting.work_item_id)
    assert transitioned.state == "ready"
    assert transitioned.phase == "feedback_ready"

    assert {:ok, recovered} =
             Reconciler.ingest(
               waiting.work_item_id,
               combined,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert recovered.replayed

    assert recovered.observation.item_tokens == [
             "review:9021:2026-07-29T21:08:00Z:CHANGES_REQUESTED"
           ]

    assert :ok = plan_review_repair!(fixture, waiting)
    assert repair_attempt_count(waiting) == 1
  end

  test "an accepted observation without an operation is revalidated before replay", fixture do
    {waiting, pull_request} = publish_successfully!(fixture)

    accepted_before_dispatch =
      review_observation(waiting, %{
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:09:00Z",
        comments: [
          %{
            id: 9_022,
            body: "This observation was persisted before its operation was claimed.",
            updated_at: "2026-07-29T21:09:00Z"
          }
        ]
      })

    {:ok, persisted} = Observation.new(accepted_before_dispatch)
    body = Jason.encode!(Observation.render(persisted))

    assert {:ok, artifact} =
             Artifacts.put(
               waiting.work_item_id,
               body,
               %{
                 artifact_id: "github-observation:accepted-before-operation",
                 kind: "github_observation",
                 external_identity: persisted.external_identity,
                 media_type: "application/json",
                 provenance: %{
                   accepted: true,
                   item_tokens: persisted.item_tokens
                 }
               },
               artifact_dir: fixture.artifacts
             )

    newer =
      review_observation(waiting, %{
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:10:00Z",
        reviews: [
          %{
            id: 9_023,
            state: "CHANGES_REQUESTED",
            body: "Please address the newer review.",
            commit_id: pull_request.head_sha,
            submitted_at: "2026-07-29T21:10:00Z"
          }
        ]
      })

    assert {:ok, %{status: :repair_ready}} =
             Reconciler.ingest(
               waiting.work_item_id,
               newer,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    current = WorkItems.get(waiting.work_item_id)

    assert {:error,
            {:stale, :github_review_not_waiting,
             %{observation_artifact_id: observation_artifact_id}}} =
             Reconciler.ingest(
               waiting.work_item_id,
               accepted_before_dispatch,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert observation_artifact_id == artifact.artifact_id
    assert WorkItems.get(waiting.work_item_id).version == current.version

    refute Enum.any?(WorkItems.list_events(waiting.work_item_id), fn event ->
             get_in(event.evidence || %{}, ["github_observation", "external_identity"]) ==
               persisted.external_identity
           end)
  end

  test "stale heads and older revisions are preserved as rejected evidence only", fixture do
    {waiting, _pull_request} = publish_successfully!(fixture)
    workspace = publication_workspace!(waiting)
    original_revision = git!(workspace, ["rev-parse", "HEAD"])

    stale_head =
      review_observation(waiting, %{
        head_sha: "superseded-head",
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:10:00Z",
        comments: [
          %{
            id: 9_003,
            body: "This belongs to the old head.",
            updated_at: "2026-07-29T21:10:00Z"
          }
        ]
      })

    assert {:error, {:stale, :github_review_head_changed, _details}} =
             Reconciler.ingest(
               waiting.work_item_id,
               stale_head,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert WorkItems.get(waiting.work_item_id).version == waiting.version
    assert git!(workspace, ["rev-parse", "HEAD"]) == original_revision

    current =
      review_observation(waiting, %{
        kind: "check_run",
        external_updated_at: "2026-07-29T21:20:00Z",
        checks: [
          %{
            id: 9_004,
            name: "test",
            status: "completed",
            conclusion: "success",
            completed_at: "2026-07-29T21:20:00Z"
          }
        ]
      })

    assert {:ok, %{status: :waiting}} =
             Reconciler.ingest(
               waiting.work_item_id,
               current,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    observed = WorkItems.get(waiting.work_item_id)

    older =
      review_observation(observed, %{
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:15:00Z",
        comments: [
          %{
            id: 9_005,
            body: "Late delivery of an older comment.",
            updated_at: "2026-07-29T21:15:00Z"
          }
        ]
      })

    assert {:error, {:stale, :github_review_revision_older, _details}} =
             Reconciler.ingest(
               waiting.work_item_id,
               older,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert WorkItems.get(waiting.work_item_id).version == observed.version
    assert git!(workspace, ["rev-parse", "HEAD"]) == original_revision
    assert repair_attempt_count(waiting) == 0

    rejected =
      waiting.work_item_id
      |> Artifacts.list_for_work_item()
      |> Enum.filter(fn artifact ->
        artifact.kind == "github_observation" and not artifact.provenance["accepted"]
      end)

    assert length(rejected) == 2
  end

  test "formatter feedback takes the mechanical fast path and returns to verification",
       fixture do
    {waiting, _pull_request} = publish_successfully!(fixture)

    observation =
      review_observation(waiting, %{
        kind: "check_run",
        external_updated_at: "2026-07-29T21:30:00Z",
        checks: [
          %{
            id: 9_006,
            name: "mix format",
            status: "completed",
            conclusion: "failure",
            completed_at: "2026-07-29T21:30:00Z"
          }
        ]
      })

    assert {:ok, %{status: :repair_ready}} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert :ok = plan_review_repair!(fixture, waiting)
    repair = repair_attempt!(waiting)
    assert repair.executor_kind == "deterministic"
    assert repair.provenance["active_phase"] == "handling_feedback"
    assert get_in(repair.provenance, ["repair_disposition", "handler"]) == "elixir_format"

    runner = fn spec, _path, _options ->
      assert spec.name == "repair_format"
      {:ok, runner_result(spec, "pass")}
    end

    assert :ok =
             RepairAttempts.perform(
               repair_job!(repair.attempt_id),
               runner: runner,
               artifact_dir: fixture.artifacts
             )

    repaired = WorkItems.get(waiting.work_item_id)
    assert repaired.state == "ready"
    assert repaired.phase == "verification_ready"
  end

  test "a failed mechanical review repair re-enters the bounded semantic policy", fixture do
    {waiting, _pull_request} = publish_successfully!(fixture)

    observation =
      review_observation(waiting, %{
        kind: "check_run",
        external_updated_at: "2026-07-29T21:35:00Z",
        checks: [
          %{
            id: 9_007,
            name: "formatter",
            status: "completed",
            conclusion: "failure",
            completed_at: "2026-07-29T21:35:00Z"
          }
        ]
      })

    assert {:ok, _result} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert :ok = plan_review_repair!(fixture, waiting)
    mechanical = repair_attempt!(waiting)

    runner = fn spec, _path, _options -> {:ok, runner_result(spec, "test_failure")} end

    assert :ok =
             RepairAttempts.perform(
               repair_job!(mechanical.attempt_id),
               runner: runner,
               artifact_dir: fixture.artifacts
             )

    repair_ready = WorkItems.get(waiting.work_item_id)
    assert repair_ready.state == "ready"
    assert repair_ready.phase == "repair_ready"

    assert :ok = plan_repair!(fixture, repair_ready)
    semantic = repair_attempt!(waiting)
    assert semantic.attempt_id != mechanical.attempt_id
    assert semantic.executor_kind == "model"
    assert semantic.caused_by_attempt.attempt_id == mechanical.attempt_id
    assert get_in(semantic.provenance, ["repair_disposition", "kind"]) == "semantic_repair"
    assert repair_attempt_count(waiting) == 2
  end

  test "a pinned clean conflict replay preserves the published head and returns to verification",
       fixture do
    {waiting, pull_request} = publish_successfully!(fixture)
    workspace = publication_workspace!(waiting)

    base_source = Path.join(fixture.root, "review-base-source")
    clone_repository!(fixture.remote, base_source)
    git!(base_source, ["config", "user.email", "test@example.com"])
    git!(base_source, ["config", "user.name", "Custode Test"])
    File.write!(Path.join(base_source, "BASE_REVIEW.md"), "new base\n")
    git!(base_source, ["add", "BASE_REVIEW.md"])
    git!(base_source, ["commit", "-m", "docs: advance review base"])
    new_base = git!(base_source, ["rev-parse", "HEAD"])
    git!(base_source, ["push", "origin", "main"])

    observation =
      review_observation(waiting, %{
        kind: "conflict",
        external_updated_at: "2026-07-29T21:40:00Z",
        base_sha: new_base,
        conflict: true
      })

    assert {:ok, %{status: :repair_ready}} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert :ok = plan_review_repair!(fixture, waiting)
    repair = repair_attempt!(waiting)
    assert repair.provenance["active_phase"] == "resolving_conflict"
    assert get_in(repair.provenance, ["repair_disposition", "handler"]) == "git_replay"

    assert :ok =
             RepairAttempts.perform(
               repair_job!(repair.attempt_id),
               artifact_dir: fixture.artifacts
             )

    finished = Attempts.get(repair.attempt_id)

    assert finished.outcome["classification"] == "pass",
           inspect(%{outcome: finished.outcome, error_details: finished.error_details})

    repaired = WorkItems.get(waiting.work_item_id)
    assert repaired.state == "ready"
    assert repaired.phase == "verification_ready"
    assert File.read!(Path.join(workspace, "BASE_REVIEW.md")) == "new base\n"
    assert git!(workspace, ["rev-parse", "HEAD"]) == pull_request.head_sha
    assert git!(workspace, ["status", "--short"]) =~ "BASE_REVIEW.md"
  end

  test "review repair policy exhaustion blocks without creating an Attempt", fixture do
    {waiting, _pull_request} = publish_successfully!(fixture)

    observation =
      review_observation(waiting, %{
        kind: "review_feedback",
        external_updated_at: "2026-07-29T21:45:00Z",
        comments: [
          %{
            id: 9_008,
            body: "Please revise the implementation.",
            updated_at: "2026-07-29T21:45:00Z"
          }
        ]
      })

    assert {:ok, _result} =
             Reconciler.ingest(
               waiting.work_item_id,
               observation,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts
             )

    assert :ok =
             plan_review_repair!(
               fixture,
               waiting,
               repair_policy: repair_policy(max_repairs: 0)
             )

    blocked = WorkItems.get(waiting.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "feedback_ready"
    assert blocked.blocked_reason["code"] == "repair_policy_exhausted"
    assert repair_attempt_count(waiting) == 0
  end

  test "a local-only publication commit is recovered and pushed without a second commit",
       fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)
    workspace = publication_workspace!(work_item)

    git!(workspace, ["add", "--all"])
    git!(workspace, ["commit", "-m", "feat: compile context and run Claude"])
    local_commit = git!(workspace, ["rev-parse", "HEAD"])

    assert remote_branch(fixture.remote, workspace_branch(work_item)) == nil

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    assert remote_branch(fixture.remote, workspace_branch(work_item)) == local_commit
    assert git!(workspace, ["rev-parse", "HEAD"]) == local_commit
  end

  test "a remote-only matching branch is adopted instead of overwritten", fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)
    workspace = publication_workspace!(work_item)
    branch = workspace_branch(work_item)
    expected_head = publication.provenance["expected_head_revision"]

    git!(workspace, ["add", "--all"])
    git!(workspace, ["commit", "-m", "feat: compile context and run Claude"])
    published_commit = git!(workspace, ["rev-parse", "HEAD"])
    git!(workspace, ["push", "origin", "#{published_commit}:refs/heads/#{branch}"])
    git!(workspace, ["reset", "--mixed", expected_head])

    assert git!(workspace, ["rev-parse", "HEAD"]) == expected_head
    assert remote_branch(fixture.remote, branch) == published_commit

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    assert git!(workspace, ["rev-parse", "HEAD"]) == published_commit
    assert remote_branch(fixture.remote, branch) == published_commit
  end

  test "an existing matching draft pull request is reused without another GitHub write",
       fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)

    assert {:error, {:simulated_crash, :after_git}} =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts,
               after_git: fn _response -> {:error, :after_git} end
             )

    commit_sha = remote_branch(fixture.remote, workspace_branch(work_item))
    seed_pull_request!(fixture, work_item, commit_sha, 812)

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    refute_receive {:open_pr, _pull_request}, 50
    assert get_in(Attempts.get(publication.attempt_id).outcome, ["pull_request", "number"]) == 812
  end

  test "a crash after the GitHub Operation replays its result without opening another PR",
       fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)

    assert {:error, {:simulated_crash, :after_pull_request}} =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts,
               after_pull_request: fn _response -> {:error, :after_pull_request} end
             )

    assert_receive {:open_pr, _pull_request}
    assert Attempts.get(publication.attempt_id).state == "running"

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    refute_receive {:open_pr, _pull_request}, 50
    assert Agent.get(fixture.repo_state, &length(&1.pull_requests)) == 1
  end

  test "publication refuses a workspace changed after verification", fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)
    workspace = publication_workspace!(work_item)

    File.write!(Path.join(workspace, "README.md"), "changed after verification\n")

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    blocked = WorkItems.get(work_item.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "publishing"
    assert blocked.blocked_reason["code"] == "publication_stale"
    refute_receive {:open_pr, _pull_request}, 50
    assert remote_branch(fixture.remote, workspace_branch(work_item)) == nil
  end

  test "publication never overwrites a divergent remote branch", fixture do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)
    branch = workspace_branch(work_item)
    base_revision = git!(fixture.repository, ["rev-parse", "HEAD"])

    git!(fixture.repository, ["push", "origin", "#{base_revision}:refs/heads/#{branch}"])

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    blocked = WorkItems.get(work_item.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.blocked_reason["code"] == "publication_stale"
    assert remote_branch(fixture.remote, branch) == base_revision
    refute_receive {:open_pr, _pull_request}, 50
  end

  test "a crash after command evidence reuses it without executing the command twice", fixture do
    work_item = implement_successfully!(fixture)
    assert :ok = dispatch_to_verifier!(fixture, work_item)
    verification = verification_attempt!(work_item)
    job = verification_job!(verification.attempt_id)
    test_pid = self()

    runner = fn spec, _path, _options ->
      send(test_pid, {:verification_ran, spec.name})
      {:ok, runner_result(spec, "pass")}
    end

    assert_raise RuntimeError, "simulated verification crash", fn ->
      VerificationAttempts.perform(job,
        runner: runner,
        artifact_dir: fixture.artifacts,
        after_command: fn result ->
          if result["name"] == "format" and not result["reused"] do
            raise "simulated verification crash"
          end

          :ok
        end
      )
    end

    assert_receive {:verification_ran, "format"}
    refute_receive {:verification_ran, _other}
    assert Attempts.get(verification.attempt_id).state == "running"

    assert :ok =
             VerificationAttempts.perform(job,
               runner: runner,
               artifact_dir: fixture.artifacts
             )

    assert_receive {:verification_ran, "test"}
    assert_receive {:verification_ran, "analysis"}
    assert_receive {:verification_ran, "repo"}
    refute_receive {:verification_ran, "format"}

    results = Attempts.get(verification.attempt_id).outcome["results"]
    assert hd(results)["name"] == "format"
    refute Map.has_key?(hd(results), "reused")

    format_results =
      work_item.work_item_id
      |> Artifacts.list_for_work_item()
      |> Enum.filter(
        &(&1.kind == "verification_command_result" and
            &1.provenance["command_name"] == "format")
      )

    assert length(format_results) == 1
  end

  test "a changed workspace cannot reuse green command evidence", fixture do
    work_item = implement_successfully!(fixture)
    assert :ok = dispatch_to_verifier!(fixture, work_item)
    verification = verification_attempt!(work_item)
    job = verification_job!(verification.attempt_id)
    test_pid = self()

    runner = fn spec, _path, _options ->
      send(test_pid, {:verification_ran, spec.name})
      {:ok, runner_result(spec, "pass")}
    end

    assert_raise RuntimeError, fn ->
      VerificationAttempts.perform(job,
        runner: runner,
        artifact_dir: fixture.artifacts,
        after_command: fn _result -> raise "crash after first command" end
      )
    end

    assert_receive {:verification_ran, "format"}

    lease = WorkspaceLeases.get_for_work_item(work_item.work_item_id)
    File.write!(Path.join(lease.workspace_path, "README.md"), "changed after evidence\n")

    refuting_runner = fn _spec, _path, _options ->
      flunk("changed workspace reused or executed old verification evidence")
    end

    assert :ok =
             VerificationAttempts.perform(job,
               runner: refuting_runner,
               artifact_dir: fixture.artifacts
             )

    finished = Attempts.get(verification.attempt_id)
    assert finished.state == "failed"
    assert finished.error_class == "policy_refusal"
    assert finished.outcome["classification"] == "policy_refusal"

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "repair_ready"
  end

  test "failed named verification results preserve focused repair evidence", fixture do
    work_item = implement_successfully!(fixture)
    assert :ok = dispatch_to_verifier!(fixture, work_item)
    verification = verification_attempt!(work_item)

    runner = fn spec, _path, _options ->
      status = if spec.name == "test", do: "test_failure", else: "pass"
      {:ok, runner_result(spec, status)}
    end

    assert :ok =
             VerificationAttempts.perform(
               verification_job!(verification.attempt_id),
               runner: runner,
               artifact_dir: fixture.artifacts
             )

    finished = Attempts.get(verification.attempt_id)
    assert finished.state == "failed"
    assert finished.error_class == "test_failure"
    assert finished.outcome["classification"] == "test_failure"

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "repair_ready"

    failure =
      work_item.work_item_id
      |> Artifacts.list_for_work_item()
      |> Enum.find(&(&1.kind == "verification_failure"))

    body = failure.location |> File.read!() |> Jason.decode!()
    assert Enum.map(body["failures"], & &1["name"]) == ["test"]
    refute get_in(body, ["failures", Access.at(0), "output"])
  end

  test "mechanical repair is linked, crash-safe, and returns through fresh verification",
       fixture do
    {work_item, failed_verification} = fail_verification!(fixture, "format", "test_failure")

    assert :ok = plan_repair!(fixture, work_item)
    repair = repair_attempt!(work_item)

    assert repair.executor_kind == "deterministic"
    assert repair.provider == "custode"
    assert repair.caused_by_attempt.attempt_id == failed_verification.attempt_id
    assert get_in(repair.provenance, ["repair_disposition", "kind"]) == "mechanical_repair"

    assert :ok = plan_repair!(fixture, work_item)
    assert repair_attempt_count(work_item) == 1
    assert repair_job_count(repair.attempt_id) == 1

    assert {:ok, body} = ContextBundles.body(repair.context_bundle)

    assert get_in(body, ["repair", "focused_failure", "failures", Access.at(0), "name"]) ==
             "format"

    assert get_in(body, ["repair", "failure_artifact", "producer_attempt_id"]) ==
             failed_verification.attempt_id

    test_pid = self()

    runner = fn spec, _path, _options ->
      send(test_pid, {:repair_ran, spec.name})
      {:ok, runner_result(spec, "pass")}
    end

    assert {:error, :simulated_crash} =
             RepairAttempts.perform(
               repair_job!(repair.attempt_id),
               runner: runner,
               artifact_dir: fixture.artifacts,
               after_result: fn _artifact -> {:error, :simulated_crash} end
             )

    assert_receive {:repair_ran, "repair_format"}
    assert Attempts.get(repair.attempt_id).state == "running"

    refuting_runner = fn _spec, _path, _options ->
      flunk("durable repair evidence was executed twice")
    end

    assert :ok =
             RepairAttempts.perform(
               repair_job!(repair.attempt_id),
               runner: refuting_runner,
               artifact_dir: fixture.artifacts
             )

    assert Attempts.get(repair.attempt_id).state == "succeeded"
    assert WorkItems.get(work_item.work_item_id).phase == "verification_ready"

    assert :ok =
             GitHubIssueVertical.perform(
               fixture.routine.id,
               work_item.work_item_id,
               oban_job_id: System.unique_integer([:positive]),
               artifact_dir: fixture.artifacts,
               verification_recipe: test_recipe()
             )

    next_verification = latest_verification_attempt!(work_item)
    assert next_verification.attempt_id != failed_verification.attempt_id
    assert next_verification.caused_by_attempt.attempt_id == repair.attempt_id

    repair_results =
      work_item.work_item_id
      |> Artifacts.list_for_work_item()
      |> Enum.filter(&(&1.kind == "repair_result"))

    assert length(repair_results) == 1
  end

  test "semantic repair is a focused linked Claude Attempt", fixture do
    {work_item, failed_verification} = fail_verification!(fixture, "test", "test_failure")

    assert :ok = plan_repair!(fixture, work_item)
    repair = repair_attempt!(work_item)

    assert repair.executor_kind == "model"
    assert repair.provider == "claude"
    assert repair.caused_by_attempt.attempt_id == failed_verification.attempt_id
    assert get_in(repair.provenance, ["repair_disposition", "kind"]) == "semantic_repair"

    test_pid = self()

    query_fun = fn prompt, options ->
      send(test_pid, {:repair_prompt, prompt})
      File.write!(Path.join(options[:working_dir], "semantic-repair.txt"), "fixed\n")

      {:ok,
       ObanClaude.Testing.structured_result(
         %{"outcome" => "success", "summary" => "focused repair complete"},
         cost_usd: 0.02,
         duration_ms: 10,
         num_turns: 1
       )}
    end

    assert :ok =
             ClaudeAttempts.perform(
               provider_job!(repair.attempt_id),
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    assert_receive {:repair_prompt, prompt}
    assert prompt =~ "Repair only the focused failure"
    assert prompt =~ "\"failure_artifact\""
    assert prompt =~ "\"test\""

    finished = Attempts.get(repair.attempt_id)
    assert finished.state == "succeeded"
    assert finished.outcome["kind"] == "claude_repair"
    assert WorkItems.get(work_item.work_item_id).phase == "verification_ready"
  end

  test "a repair-time human question records a typed wait disposition", fixture do
    {work_item, _failed_verification} = fail_verification!(fixture, "test", "test_failure")
    assert :ok = plan_repair!(fixture, work_item)
    repair = repair_attempt!(work_item)

    query_fun =
      ObanClaude.Testing.respond(
        ObanClaude.Testing.structured_result(%{
          "outcome" => "human_question",
          "summary" => "repair needs an operator decision",
          "question" => "Which compatibility behavior should the repair preserve?"
        })
      )

    assert :ok =
             ClaudeAttempts.perform(
               provider_job!(repair.attempt_id),
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    waiting = WorkItems.get(work_item.work_item_id)
    assert waiting.state == "waiting"
    assert waiting.phase == "repairing"

    assert get_in(waiting.waiting_condition, ["repair_disposition", "kind"]) == "human_ask"

    assert waiting.waiting_condition["question"] ==
             "Which compatibility behavior should the repair preserve?"

    event = latest_transition_event(work_item)
    assert get_in(event.evidence, ["repair_disposition", "kind"]) == "human_ask"
  end

  test "an unrepairable semantic result records a typed terminal block", fixture do
    {work_item, _failed_verification} = fail_verification!(fixture, "test", "test_failure")
    assert :ok = plan_repair!(fixture, work_item)
    repair = repair_attempt!(work_item)

    query_fun =
      ObanClaude.Testing.respond(
        ObanClaude.Testing.structured_result(%{
          "outcome" => "blocked",
          "summary" => "required source remains unavailable",
          "reason" => "missing dependency"
        })
      )

    assert :ok =
             ClaudeAttempts.perform(
               provider_job!(repair.attempt_id),
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    blocked = WorkItems.get(work_item.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "repairing"
    assert blocked.blocked_reason["code"] == "repair_terminal_block"

    assert get_in(blocked.blocked_reason, ["repair_disposition", "kind"]) ==
             "terminal_block"

    event = latest_transition_event(work_item)
    assert get_in(event.evidence, ["repair_disposition", "kind"]) == "terminal_block"
  end

  test "infrastructure retry is deterministic and never masquerades as semantic repair",
       fixture do
    {work_item, failed_verification} =
      fail_verification!(fixture, "test", "infrastructure_error")

    assert :ok = plan_repair!(fixture, work_item)
    retry_attempt = repair_attempt!(work_item)

    assert retry_attempt.executor_kind == "deterministic"
    assert retry_attempt.profile == "infrastructure_retry"
    assert retry_attempt.caused_by_attempt.attempt_id == failed_verification.attempt_id

    assert get_in(retry_attempt.provenance, ["repair_disposition", "kind"]) ==
             "infrastructure_retry"

    assert repair_job_count(retry_attempt.attempt_id) == 1
    assert provider_job_count(retry_attempt.attempt_id) == 0

    assert :ok =
             RepairAttempts.perform(
               repair_job!(retry_attempt.attempt_id),
               artifact_dir: fixture.artifacts
             )

    finished = Attempts.get(retry_attempt.attempt_id)
    assert finished.state == "succeeded"
    assert finished.usage["commands"] == 0
    assert WorkItems.get(work_item.work_item_id).phase == "verification_ready"
  end

  test "exhausted repair policy creates one stable blocked transition", fixture do
    {work_item, _failed_verification} = fail_verification!(fixture, "test", "test_failure")
    exhausted = repair_policy(max_repairs: 0)

    assert :ok = plan_repair!(fixture, work_item, repair_policy: exhausted)

    blocked = WorkItems.get(work_item.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "repair_ready"
    assert blocked.blocked_reason["code"] == "repair_policy_exhausted"
    assert blocked.blocked_reason["limit"]["name"] == "repairs"
    assert repair_attempt_count(work_item) == 0

    transitions_before = repair_decision_event_count(work_item)
    assert transitions_before == 1

    assert :ok = plan_repair!(fixture, work_item, repair_policy: exhausted)
    assert repair_decision_event_count(work_item) == transitions_before
    assert WorkItems.get(work_item.work_item_id).version == blocked.version
  end

  test "changed workspace invalidates focused failure evidence before repair", fixture do
    {work_item, _failed_verification} = fail_verification!(fixture, "test", "test_failure")
    lease = WorkspaceLeases.get_for_work_item(work_item.work_item_id)
    File.write!(Path.join(lease.workspace_path, "after-failure.txt"), "stale\n")

    assert {:error, :focused_failure_workspace_changed} =
             plan_repair!(fixture, work_item)

    assert repair_attempt_count(work_item) == 0

    unchanged = WorkItems.get(work_item.work_item_id)
    assert unchanged.state == "ready"
    assert unchanged.phase == "repair_ready"
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
      title: "feat: compile context and run Claude",
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

  defp dispatch_to_provider!(fixture, work_item, options \\ []) do
    options =
      [
        oban_job_id: System.unique_integer([:positive]),
        workspace_root: fixture.workspaces,
        artifact_dir: fixture.artifacts
      ]
      |> Keyword.merge(options)

    assert :ok =
             GitHubIssueVertical.perform(
               fixture.routine.id,
               work_item.work_item_id,
               options
             )
  end

  defp implement_successfully!(fixture) do
    work_item = ingest!(fixture)
    assert :ok = dispatch_to_provider!(fixture, work_item)
    implementation = implementation_attempt!(work_item)
    job = provider_job!(implementation.attempt_id)

    query_fun = fn _prompt, options ->
      File.write!(Path.join(options[:working_dir], "README.md"), "implemented\n")

      {:ok,
       ObanClaude.Testing.structured_result(
         %{"outcome" => "success", "summary" => "implementation ready for verification"},
         result: "done",
         session_id: "session-verification",
         cost_usd: 0.01,
         duration_ms: 25,
         num_turns: 1
       )}
    end

    assert :ok =
             ClaudeAttempts.perform(job,
               query_fun: query_fun,
               artifact_dir: fixture.artifacts
             )

    WorkItems.get(work_item.work_item_id)
  end

  defp dispatch_to_verifier!(fixture, work_item) do
    assert :ok =
             GitHubIssueVertical.perform(
               fixture.routine.id,
               work_item.work_item_id,
               oban_job_id: System.unique_integer([:positive]),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               verification_recipe: test_recipe()
             )
  end

  defp verify_successfully!(fixture) do
    work_item = implement_successfully!(fixture)
    assert :ok = dispatch_to_verifier!(fixture, work_item)
    verification = latest_verification_attempt!(work_item)

    assert :ok =
             VerificationAttempts.perform(
               verification_job!(verification.attempt_id),
               artifact_dir: fixture.artifacts
             )

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "publication_ready"
    ready
  end

  defp publish_successfully!(fixture) do
    work_item = verify_successfully!(fixture)
    assert :ok = plan_publication!(fixture, work_item)
    publication = publication_attempt!(work_item)

    assert :ok =
             PublicationAttempts.perform(
               publication_job!(publication.attempt_id),
               artifact_dir: fixture.artifacts
             )

    assert_receive {:open_pr, pull_request}
    waiting = WorkItems.get(work_item.work_item_id)
    assert waiting.state == "waiting"
    assert waiting.phase == "awaiting_review"
    {waiting, pull_request}
  end

  defp prepare_merge_gate!(fixture) do
    {waiting, pull_request} = publish_successfully!(fixture)

    pull_request =
      update_pull_request!(fixture, pull_request.number, %{
        base_sha: git!(fixture.repository, ["rev-parse", "HEAD"]),
        draft: false,
        mergeable: true,
        mergeable_state: "clean",
        merged: false,
        merge_commit_sha: nil,
        updated_at: "2026-07-29T21:10:00Z"
      })

    put_env!(:publication_review_snapshot, clean_merge_snapshot(pull_request))
    put_env!(:publication_review_state, {:reviewed, "approving review"})

    assert {:ok, %{status: :merge_ready, gate: %WorkGate{} = gate}} =
             Reconciler.reconcile(
               waiting.work_item_id,
               routine_id: fixture.routine.id,
               artifact_dir: fixture.artifacts,
               correlation_id: "github-merge:test-correlation",
               causation_id: "github-merge:test-causation"
             )

    merge_ready = WorkItems.get(waiting.work_item_id)
    assert merge_ready.state == "waiting"
    assert merge_ready.phase == "merge_ready"
    assert merge_ready.waiting_condition["gate_id"] == gate.gate_id

    {waiting, pull_request, gate}
  end

  defp clean_merge_snapshot(pull_request) do
    %{
      reviews: [
        %{
          id: 9_100,
          author: "reviewer",
          state: "APPROVED",
          commit_id: pull_request.head_sha,
          submitted_at: "2026-07-29T21:09:00Z"
        }
      ],
      comments: [],
      checks: [
        %{
          id: 9_101,
          name: "test",
          status: "completed",
          conclusion: "success",
          started_at: "2026-07-29T21:08:00Z",
          completed_at: "2026-07-29T21:09:00Z"
        }
      ]
    }
  end

  defp failed_merge_snapshot(pull_request) do
    pull_request
    |> clean_merge_snapshot()
    |> put_in([:checks, Access.at(0), :conclusion], "failure")
  end

  defp update_pull_request!(fixture, number, attrs) do
    Agent.get_and_update(fixture.repo_state, fn state ->
      {pull_request, rest} = Enum.split_with(state.pull_requests, &(&1.number == number))
      [pull_request] = pull_request
      updated = Map.merge(pull_request, attrs)
      {updated, %{state | pull_requests: [updated | rest]}}
    end)
  end

  defp assert_stale_merge_gate!(waiting, gate) do
    assert {:error, {:stale, changes, stale_gate}} =
             GitHubMerge.approve(
               gate.gate_id,
               actor: %{kind: :operator, id: "maintainer"},
               transport: :cli
             )

    assert stale_gate.status == "stale"
    assert map_size(changes) > 0
    refute_receive {:merge_pr_at_head, _number, _head}, 50
    assert WorkItems.get(waiting.work_item_id).phase == "merge_ready"
  end

  defp insert_running_merge_call!(gate) do
    %{
      call_id: Ecto.UUID.generate(),
      operation: gate.operation,
      arguments: gate.arguments,
      actor: %{"kind" => "operator", "id" => "crashed-approver"},
      transport: "cli",
      risk: "external_write",
      idempotency_scope: "github-merge:#{gate.work_item.work_item_id}",
      idempotency_key: gate.operation_idempotency_key,
      expected_versions: %{"work_item" => gate.work_item_version},
      correlation_id: gate.correlation_id,
      causation_id: gate.causation_id,
      mission_id: gate.mission.mission_id,
      work_item_id: gate.work_item.work_item_id,
      status: "running"
    }
    |> OperationCall.create_changeset()
    |> Repo.insert!()
  end

  defp review_observation(work_item, attrs) do
    condition = work_item.waiting_condition

    %{
      repository: condition["repository"],
      pull_request_number: condition["number"],
      head_sha: condition["head_sha"],
      external_updated_at: "2026-07-29T21:00:00Z",
      kind: "snapshot"
    }
    |> Map.merge(attrs)
  end

  defp plan_publication!(fixture, work_item) do
    GitHubIssueVertical.perform(
      fixture.routine.id,
      work_item.work_item_id,
      oban_job_id: System.unique_integer([:positive]),
      artifact_dir: fixture.artifacts
    )
  end

  defp plan_review_repair!(fixture, work_item, options \\ []) do
    defaults = [
      oban_job_id: System.unique_integer([:positive]),
      artifact_dir: fixture.artifacts
    ]

    GitHubIssueVertical.perform(
      fixture.routine.id,
      work_item.work_item_id,
      Keyword.merge(defaults, options)
    )
  end

  defp fail_verification!(fixture, failed_name, status) do
    work_item = implement_successfully!(fixture)
    assert :ok = dispatch_to_verifier!(fixture, work_item)
    verification = latest_verification_attempt!(work_item)

    runner = fn spec, _path, _options ->
      result_status = if spec.name == failed_name, do: status, else: "pass"
      {:ok, runner_result(spec, result_status)}
    end

    assert :ok =
             VerificationAttempts.perform(
               verification_job!(verification.attempt_id),
               runner: runner,
               artifact_dir: fixture.artifacts
             )

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "repair_ready"

    {work_item, Attempts.get(verification.attempt_id)}
  end

  defp plan_repair!(fixture, work_item, options \\ []) do
    defaults = [
      oban_job_id: System.unique_integer([:positive]),
      artifact_dir: fixture.artifacts
    ]

    GitHubIssueVertical.perform(
      fixture.routine.id,
      work_item.work_item_id,
      Keyword.merge(defaults, options)
    )
  end

  defp implementation_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.find(&(&1.executor_kind == "model"))
  end

  defp verification_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.find(&(get_in(&1.provenance, ["purpose"]) == "github_issue_verification"))
  end

  defp latest_verification_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(&(get_in(&1.provenance, ["purpose"]) == "github_issue_verification"))
  end

  defp repair_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(&(get_in(&1.provenance, ["purpose"]) == "github_issue_repair"))
  end

  defp repair_attempt_count(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.count(&(get_in(&1.provenance, ["purpose"]) == "github_issue_repair"))
  end

  defp publication_attempt!(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(&(get_in(&1.provenance, ["purpose"]) == "github_issue_publication"))
  end

  defp publication_attempt_count(work_item) do
    work_item.work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.count(&(get_in(&1.provenance, ["purpose"]) == "github_issue_publication"))
  end

  defp provider_job!(attempt_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker in ["Custode.ClaudeAttemptJob", "Custode.CodexAttemptJob"] and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp provider_job_count(attempt_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker in ["Custode.ClaudeAttemptJob", "Custode.CodexAttemptJob"] and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp coordinator_job!(work_item_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.GitHubIssueVerticalJob" and
            fragment("json_extract(?, '$.work_item_id')", job.args) == ^work_item_id,
        order_by: [desc: job.id],
        limit: 1
      )
    )
  end

  defp verification_job!(attempt_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.VerificationAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp verification_job_count(attempt_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.VerificationAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp repair_job!(attempt_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.RepairAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp repair_job_count(attempt_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.RepairAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp publication_job!(attempt_id) do
    Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.PublicationAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp publication_job_count(attempt_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.PublicationAttemptJob" and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp publication_workspace!(work_item) do
    work_item.work_item_id
    |> WorkspaceLeases.get_for_work_item()
    |> Map.fetch!(:workspace_path)
  end

  defp workspace_branch(work_item) do
    work_item.work_item_id
    |> WorkspaceLeases.get_for_work_item()
    |> Map.fetch!(:branch)
  end

  defp seed_pull_request!(fixture, work_item, commit_sha, number) do
    branch = workspace_branch(work_item)

    pull_request = %{
      number: number,
      title: "feat: compile context and run Claude",
      state: "open",
      draft: true,
      base: "main",
      base_sha: nil,
      head: branch,
      head_sha: commit_sha,
      updated_at: "2026-07-29T20:00:00Z",
      url: "https://github.com/genagent/custode/pull/#{number}",
      body: "Closes #368."
    }

    Agent.update(fixture.repo_state, fn state ->
      %{state | pull_requests: [pull_request | state.pull_requests]}
    end)
  end

  defp remote_branch(remote, branch) do
    case System.cmd(
           "git",
           ["--git-dir", remote, "rev-parse", "--verify", "refs/heads/#{branch}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp repair_decision_event_count(work_item) do
    work_item.work_item_id
    |> WorkItems.list_events()
    |> Enum.count(
      &(get_in(&1.evidence || %{}, ["repair_disposition", "kind"]) in Disposition.kinds())
    )
  end

  defp latest_transition_event(work_item) do
    work_item.work_item_id
    |> WorkItems.list_events()
    |> Enum.reverse()
    |> Enum.find(&(&1.kind == "work_item.transitioned"))
  end

  defp repair_policy(overrides) do
    %{
      version: "test-repair-policy",
      max_infrastructure_retries: 2,
      max_repairs: 2,
      max_elapsed_ms: 60_000,
      max_spend_usd: 1.0
    }
    |> Map.merge(Map.new(overrides))
  end

  defp test_recipe do
    {:ok, recipe} =
      Recipe.new(%{
        name: "test_verification",
        version: "1",
        commands: [
          verification_command("format", "format"),
          verification_command("test", "test"),
          verification_command("analysis", "static_analysis"),
          verification_command("repo", "repository")
        ]
      })

    recipe
  end

  defp verification_command(name, category) do
    %{
      name: name,
      category: category,
      argv: ["/usr/bin/true"],
      working_directory: ".",
      environment_allowlist: ["PATH"],
      environment: %{},
      timeout_ms: 5_000,
      output_limit_bytes: 16_384,
      tail_bytes: 1_024,
      expected_exit_codes: [0],
      risk: "read",
      shell: false,
      reviewed: true
    }
  end

  defp runner_result(%CommandSpec{} = spec, status) do
    %{
      "name" => spec.name,
      "category" => spec.category,
      "status" => status,
      "reason" => if(status == "pass", do: nil, else: "fixture failure"),
      "exit_code" => if(status == "pass", do: 0, else: 1),
      "duration_ms" => 1,
      "command_spec_digest" => spec.digest,
      "runner_version" => "fixture-runner-v1",
      "stdout_bytes" => 0,
      "stderr_bytes" => 0,
      "stdout_tail" => "",
      "stderr_tail" => "",
      "stdout_tail_encoding" => "utf-8",
      "stderr_tail_encoding" => "utf-8",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "output_limit_bytes" => spec.output_limit_bytes,
      "output" => %{}
    }
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

  defp init_remote!(repository, remote) do
    case System.cmd("git", ["init", "--bare", remote], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git init --bare failed (#{status}): #{output}")
    end

    git!(repository, ["remote", "add", "origin", remote])
    git!(repository, ["push", "-u", "origin", "main"])
  end

  defp clone_repository!(remote, path) do
    case System.cmd("git", ["clone", "--branch", "main", remote, path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git clone failed (#{status}): #{output}")
    end
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
            "Custode.CodexAttemptJob",
            "Custode.GitHubIssueVerticalJob",
            "Custode.PublicationAttemptJob",
            "Custode.RepairAttemptJob",
            "Custode.VerificationAttemptJob",
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
