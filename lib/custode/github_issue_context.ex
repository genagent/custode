defmodule Custode.GitHubIssueContext do
  @moduledoc """
  Reproducible ContextBundles for the bounded GitHub issue implementation pilot.

  The compiler reads only durable records and the configured compatibility
  routine. Volatile provider state never enters the bundle.
  """

  alias Custode.{
    Attempts,
    ContextBundles,
    Memory,
    Missions,
    RoleBindings,
    RoleTemplates,
    WorkItems,
    WorkspaceLease,
    WorkspaceLeases
  }

  @allowed_tools ~w(Read Glob Grep Edit Write)
  @disallowed_tools ~w(Bash NotebookEdit WebFetch WebSearch Task)

  @doc "The least-privilege Claude tool contract recorded in every implementation bundle."
  def capabilities do
    %{
      "tools" => %{
        "allowed" => @allowed_tools,
        "disallowed" => @disallowed_tools
      },
      "operations" => []
    }
  end

  @doc "The schema-enforced result contract for one implementation turn."
  def output_contract do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["outcome", "summary"],
      "properties" => %{
        "outcome" => %{
          "type" => "string",
          "enum" => ["success", "semantic_follow_up", "human_question", "blocked"]
        },
        "summary" => %{"type" => "string"},
        "question" => %{"type" => ["string", "null"]},
        "reason" => %{"type" => ["string", "null"]}
      }
    }
  end

  @doc "A small bootstrap dossier used by the deterministic workspace preparation Attempt."
  def preparation_bundle(routine, work_item, repository_id, base_revision, options \\ []) do
    body = %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => policy(routine, work_item),
      "recipe" => %{
        "kind" => "workspace_preparation",
        "version" => "workspace-lease-v1",
        "legacy_routine_id" => routine.id
      },
      "prior_evidence" => [],
      "external_revision" => WorkItems.latest_source_snapshot(work_item.work_item_id),
      "workspace_revision" => %{
        "repository_id" => repository_id,
        "base_revision" => base_revision
      },
      "capabilities" => %{"tools" => [], "operations" => []},
      "output_contract" => %{"kind" => "workspace_lease"}
    }

    ContextBundles.create(
      work_item.work_item_id,
      body,
      artifact_options(options,
        provenance: %{
          compiler: "github_issue_context",
          purpose: "workspace_preparation",
          legacy_routine_id: routine.id
        }
      )
    )
  end

  @doc "Compile or reuse the exact dossier consumed by the Claude implementation Attempt."
  def compile(routine, work_item, %WorkspaceLease{} = lease, options \\ []) do
    with binding when not is_nil(binding) <- RoleBindings.get_by_legacy_routine(routine.id),
         {:ok, template} <- RoleTemplates.fetch(binding.template_key),
         mission when not is_nil(mission) <- Missions.get(work_item.mission.mission_id),
         body <- implementation_body(routine, work_item, mission, binding, template, lease),
         {:ok, {_status, bundle}} <-
           ContextBundles.create(
             work_item.work_item_id,
             body,
             artifact_options(options,
               provenance: %{
                 compiler: "github_issue_context",
                 purpose: "implementation",
                 legacy_routine_id: routine.id,
                 role_binding_id: binding.binding_id,
                 role_template_version: template.version,
                 workspace_lease_id: lease.lease_id
               }
             )
           ) do
      {:ok, %{bundle: bundle, binding: binding, template: template, body: body}}
    else
      nil -> {:error, {:missing_context_authority, routine.id}}
      :error -> {:error, {:unknown_role_template, routine.id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Recover the exact implementation dossier selected by the compiling transition."
  def latest_implementation(routine, work_item) do
    with binding when not is_nil(binding) <- RoleBindings.get_by_legacy_routine(routine.id),
         {:ok, template} <- RoleTemplates.fetch(binding.template_key),
         bundle when not is_nil(bundle) <- latest_implementation_bundle(work_item, routine.id),
         {:ok, body} <- ContextBundles.body(bundle) do
      {:ok, %{bundle: bundle, binding: binding, template: template, body: body}}
    else
      nil -> {:error, {:missing_implementation_context, work_item.work_item_id}}
      :error -> {:error, {:unknown_role_template, routine.id}}
      {:error, _reason} = error -> error
    end
  end

  def allowed_tools, do: @allowed_tools
  def disallowed_tools, do: @disallowed_tools

  defp implementation_body(routine, work_item, mission, binding, template, lease) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => policy(routine, work_item),
      "recipe" => %{
        "work_kind" => "#{work_item.kind}@#{work_item.workflow_version}",
        "role_template" => %{
          "key" => template.key,
          "version" => template.version,
          "recipe" => template.recipe
        },
        "legacy_routine_id" => routine.id
      },
      "prior_evidence" => prior_evidence(work_item.work_item_id),
      "external_revision" => WorkItems.latest_source_snapshot(work_item.work_item_id),
      "workspace_revision" => workspace_revision(lease),
      "mission" => Missions.render(mission),
      "role_binding" => RoleBindings.render(binding),
      "knowledge" => knowledge(routine.id),
      "issue_snapshot" => WorkItems.latest_source_snapshot(work_item.work_item_id),
      "capabilities" => capabilities(),
      "output_contract" => output_contract()
    }
  end

  defp policy(routine, work_item) do
    mission = work_item.mission

    %{
      "work_item_policy_ref" => work_item.policy_ref,
      "mission_policy_ref" => mission.policy_ref,
      "mission_budget_ref" => mission.budget_ref,
      "budget" => %{
        "max_budget_usd" => routine.max_budget_usd,
        "daily_budget_usd" => routine.daily_budget_usd,
        "daily_budget_tokens" => routine.daily_budget_tokens,
        "max_turns" => routine.max_turns,
        "timeout_ms" => routine.timeout_ms
      }
    }
  end

  defp workspace_revision(lease) do
    rendered = WorkspaceLeases.render(lease)

    Map.take(rendered, [
      :lease_id,
      :repository_id,
      :repository_path,
      :workspace_identity,
      :workspace_path,
      :branch,
      :base_ref,
      :expected_base_revision,
      :observed_base_revision,
      :landing_scope
    ])
  end

  defp prior_evidence(work_item_id) do
    work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.map(fn attempt ->
      %{
        "attempt_id" => attempt.attempt_id,
        "executor_kind" => attempt.executor_kind,
        "provider" => attempt.provider,
        "profile" => attempt.profile,
        "recipe_version" => attempt.recipe_version,
        "state" => attempt.state,
        "context_digest" => attempt.context_digest,
        "expected_work_item_version" => attempt.expected_work_item_version,
        "usage" => attempt.usage,
        "outcome" => attempt.outcome,
        "error_class" => attempt.error_class,
        "error_details" => attempt.error_details,
        "started_at" => iso8601(attempt.started_at),
        "finished_at" => iso8601(attempt.finished_at)
      }
    end)
  end

  defp knowledge(routine_id) do
    routine_id
    |> Memory.recall()
    |> Enum.map(fn entry ->
      %{
        "key" => entry.key,
        "value" => entry.value,
        "provenance" => %{
          "kind" => "legacy_memory",
          "legacy_routine_id" => routine_id,
          "inserted_at" => iso8601(entry.inserted_at),
          "updated_at" => iso8601(entry.updated_at)
        }
      }
    end)
  end

  defp artifact_options(options, provenance: provenance) do
    [
      artifact_dir: Keyword.get(options, :artifact_dir),
      provenance: provenance,
      retention: %{until: "work_item_terminal"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp latest_implementation_bundle(work_item, routine_id) do
    context_bundle_id =
      work_item.work_item_id
      |> WorkItems.list_events()
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        if event.after_phase == "implementation_ready" do
          get_in(event.evidence, ["context_bundle_digest", "context_bundle_id"])
        end
      end)

    case ContextBundles.get(context_bundle_id) do
      %{
        provenance: %{
          "purpose" => "implementation",
          "legacy_routine_id" => ^routine_id
        }
      } = bundle ->
        bundle

      _missing_or_wrong ->
        nil
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
