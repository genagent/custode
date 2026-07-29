defmodule Custode.VerificationContext do
  @moduledoc """
  Reproducible deterministic verification dossiers.

  The implementation dossier remains immutable. Verification adds the exact
  reviewed recipe, the implementation outcome, and a content-sensitive
  workspace revision in a new ContextBundle. Database-native RoleBinding
  overrides already change through the audited `role_binding.update`
  operation; legacy bindings continue to use the declarative registry.
  """

  alias Custode.{
    Attempt,
    Attempts,
    ContextBundles,
    WorkspaceLease,
    WorkspaceLeases
  }

  alias Custode.Verification.{Recipe, Recipes}
  alias Custode.Workspace.Git

  @doc "Compile or reuse the exact dossier for a verification Attempt."
  def compile(routine, work_item, %WorkspaceLease{} = lease, options \\ []) do
    with %Attempt{} = implementation <- implementation_attempt(work_item.work_item_id),
         {:ok, implementation_body} <- ContextBundles.body(implementation.context_bundle),
         {:ok, recipe, recipe_authority} <-
           recipe(lease, implementation.role_binding, options),
         {:ok, workspace_revision} <- Git.workspace_revision(lease.workspace_path),
         body <-
           verification_body(
             implementation_body,
             implementation,
             recipe,
             recipe_authority,
             lease,
             workspace_revision
           ),
         {:ok, {_status, bundle}} <-
           ContextBundles.create(
             work_item.work_item_id,
             body,
             artifact_options(options,
               provenance: %{
                 compiler: "verification_context",
                 purpose: "verification",
                 legacy_routine_id: routine.id,
                 implementation_attempt_id: implementation.attempt_id,
                 verification_recipe_digest: recipe.digest,
                 verification_recipe_authority: recipe_authority,
                 workspace_lease_id: lease.lease_id,
                 workspace_revision: workspace_revision["revision"]
               }
             )
           ) do
      {:ok,
       %{
         bundle: bundle,
         body: body,
         recipe: recipe,
         recipe_authority: recipe_authority,
         implementation_attempt: implementation,
         workspace_revision: workspace_revision
       }}
    else
      nil -> {:error, {:implementation_attempt_missing, work_item.work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  defp implementation_attempt(work_item_id) do
    work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(fn attempt ->
      attempt.executor_kind == "model" and attempt.provider == "claude" and
        attempt.state == "succeeded" and
        get_in(attempt.outcome || %{}, ["proposal", "phase"]) == "verification_ready"
    end)
  end

  defp recipe(lease, role_binding, options) do
    case Keyword.get(options, :verification_recipe) do
      %Recipe{} = recipe ->
        {:ok, recipe, "internal_override"}

      nil ->
        binding_recipe(role_binding, lease)

      attrs ->
        with {:ok, recipe} <- Recipe.new(attrs) do
          {:ok, recipe, "internal_override"}
        end
    end
  end

  defp binding_recipe(nil, lease), do: registry_recipe(lease)

  defp binding_recipe(role_binding, lease) do
    case get_in(role_binding.scoped_overrides, ["verification_recipe"]) do
      nil ->
        registry_recipe(lease)

      %{"name" => name, "version" => version} = reference
      when map_size(reference) == 2 ->
        with {:ok, recipe} <-
               Recipes.fetch(
                 name,
                 version,
                 repository_path: lease.repository_path
               ) do
          {:ok, recipe, "role_binding_override"}
        end

      _unreviewed_commands ->
        {:error, :verification_recipe_reference_required}
    end
  end

  defp registry_recipe(lease) do
    with {:ok, recipe} <-
           Recipes.for_workspace(
             lease.workspace_path,
             repository_path: lease.repository_path
           ) do
      {:ok, recipe, "declarative_registry"}
    end
  end

  defp verification_body(
         body,
         implementation,
         recipe,
         recipe_authority,
         lease,
         revision
       ) do
    body
    |> Map.put(
      "recipe",
      body
      |> Map.get("recipe", %{})
      |> Map.put("verification", Recipe.render(recipe))
      |> Map.put("verification_authority", recipe_authority)
    )
    |> Map.put(
      "prior_evidence",
      Map.get(body, "prior_evidence", []) ++ [implementation_evidence(implementation)]
    )
    |> Map.put(
      "workspace_revision",
      lease
      |> WorkspaceLeases.render()
      |> Map.take([
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
      |> Map.merge(revision)
    )
    |> Map.put("capabilities", %{"tools" => [], "operations" => []})
    |> Map.put("output_contract", %{
      "kind" => "deterministic_verification",
      "result_statuses" => [
        "pass",
        "test_failure",
        "policy_refusal",
        "timeout",
        "infrastructure_error",
        "cancellation"
      ]
    })
  end

  defp implementation_evidence(attempt) do
    %{
      "attempt_id" => attempt.attempt_id,
      "context_bundle_id" => attempt.context_bundle.context_bundle_id,
      "context_digest" => attempt.context_digest,
      "state" => attempt.state,
      "usage" => attempt.usage,
      "outcome" => attempt.outcome,
      "finished_at" => attempt.finished_at && DateTime.to_iso8601(attempt.finished_at)
    }
  end

  defp artifact_options(options, provenance: provenance) do
    [
      artifact_dir: Keyword.get(options, :artifact_dir),
      provenance: provenance,
      retention: %{until: "work_item_terminal"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
