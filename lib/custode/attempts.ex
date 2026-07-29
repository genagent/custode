defmodule Custode.Attempts do
  @moduledoc """
  Durable lifecycle for one bounded logical execution.

  Physical delivery retries reuse the same Attempt through caller-stable
  `attempt_id` or `oban_job_id`. A deliberate semantic repair is a new row
  linked through `caused_by_attempt_id`.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Attempt,
    ContextBundles,
    Repo,
    RoleBindings,
    WorkItems
  }

  @spec get(String.t()) :: Attempt.t() | nil
  def get(attempt_id) do
    Attempt
    |> Repo.get_by(attempt_id: attempt_id)
    |> preload()
  end

  @spec list_for_work_item(String.t()) :: [Attempt.t()]
  def list_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        []

      work_item ->
        from(attempt in Attempt,
          where: attempt.work_item_id == ^work_item.id,
          order_by: [asc: attempt.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&preload/1)
    end
  end

  @doc """
  Queue one logical Attempt.

  Calling this again with the same `attempt_id`, or with the same non-nil
  `oban_job_id`, returns the existing row and cannot create duplicate usage.
  """
  def create(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> atomize() |> normalize_map_fields()
    attempt_id = attrs[:attempt_id] || Ecto.UUID.generate()

    Repo.transaction(
      fn ->
        case Repo.get_by(Attempt, attempt_id: attempt_id) do
          %Attempt{} = existing -> existing_result(existing, attrs)
          nil -> create_or_reuse_job(attempt_id, attrs)
        end
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  @doc "Start a queued Attempt, idempotently binding its physical dispatch references."
  def start(attempt_id, refs \\ %{}) when is_map(refs) or is_list(refs) do
    refs = atomize(refs)

    Repo.transaction(
      fn ->
        case Repo.get_by(Attempt, attempt_id: attempt_id) do
          nil ->
            Repo.rollback({:unknown_attempt, attempt_id})

          %Attempt{state: "queued"} = attempt ->
            attrs =
              refs
              |> Map.take([:oban_job_id, :workflow_run_id])
              |> Map.merge(%{state: "running", started_at: DateTime.utc_now()})

            update_or_rollback(Attempt.start_changeset(attempt, attrs))

          %Attempt{state: "running"} = attempt ->
            ensure_refs_match!(attempt, refs)
            bind_missing_refs(attempt, refs)

          %Attempt{} = attempt ->
            Repo.rollback({:attempt_terminal, attempt.state})
        end
      end,
      mode: :immediate
    )
    |> unwrap_attempt()
  end

  @doc """
  Finish an Attempt exactly once.

  Repeated physical callbacks return the first terminal record unchanged, so
  logical usage and outcome cannot be counted twice.
  """
  def finish(attempt_id, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> atomize() |> normalize_map_fields()

    Repo.transaction(
      fn ->
        case Repo.get_by(Attempt, attempt_id: attempt_id) do
          nil ->
            Repo.rollback({:unknown_attempt, attempt_id})

          %Attempt{} = attempt when attempt.state in ~w(queued running) ->
            finish_attrs =
              attrs
              |> Map.take([
                :state,
                :usage,
                :outcome,
                :error_class,
                :error_details,
                :provider_continuation
              ])
              |> Map.put(:finished_at, DateTime.utc_now())
              |> Map.put_new(:usage, %{})

            update_or_rollback(Attempt.finish_changeset(attempt, finish_attrs))

          %Attempt{} = attempt ->
            attempt
        end
      end,
      mode: :immediate
    )
    |> unwrap_attempt()
  end

  @doc "Create a new logical try causally linked to one terminal Attempt."
  def repair(previous_attempt_id, attrs) when is_map(attrs) or is_list(attrs) do
    case get(previous_attempt_id) do
      nil ->
        {:error, {:unknown_attempt, previous_attempt_id}}

      %Attempt{} = previous ->
        if Attempt.terminal?(previous) do
          attrs =
            attrs
            |> atomize()
            |> Map.put_new(:work_item_id, previous.work_item.work_item_id)
            |> Map.put(:caused_by_attempt_id, previous.attempt_id)
            |> Map.put_new(:attempt_id, Ecto.UUID.generate())

          create(attrs)
        else
          {:error, {:attempt_nonterminal, previous.state}}
        end
    end
  end

  @doc "A restart-safe explanation containing the immutable dossier and execution record."
  def explain(attempt_id) do
    case get(attempt_id) do
      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      attempt ->
        case ContextBundles.body(attempt.context_bundle) do
          {:ok, context_body} ->
            {:ok,
             render(attempt)
             |> Map.put(:context_bundle, ContextBundles.render(attempt.context_bundle))
             |> Map.put(:context_body, context_body)}

          {:error, reason} ->
            {:error, {:context_unavailable, reason}}
        end
    end
  end

  @spec render(Attempt.t()) :: map()
  def render(%Attempt{} = attempt) do
    attempt = preload(attempt)

    %{
      attempt_id: attempt.attempt_id,
      work_item_id: attempt.work_item.work_item_id,
      mission_id: attempt.work_item.mission.mission_id,
      role_binding_id: attempt.role_binding && attempt.role_binding.binding_id,
      context_bundle_id: attempt.context_bundle.context_bundle_id,
      caused_by_attempt_id: attempt.caused_by_attempt && attempt.caused_by_attempt.attempt_id,
      executor_kind: attempt.executor_kind,
      provider: attempt.provider,
      profile: attempt.profile,
      recipe_version: attempt.recipe_version,
      state: attempt.state,
      context_digest: attempt.context_digest,
      oban_job_id: attempt.oban_job_id,
      workflow_run_id: attempt.workflow_run_id,
      provider_continuation: attempt.provider_continuation,
      expected_work_item_version: attempt.expected_work_item_version,
      provenance: attempt.provenance,
      started_at: attempt.started_at,
      finished_at: attempt.finished_at,
      usage: attempt.usage,
      outcome: attempt.outcome,
      error_class: attempt.error_class,
      error_details: attempt.error_details
    }
  end

  defp create_or_reuse_job(attempt_id, attrs) do
    case existing_by_job(attrs[:oban_job_id]) do
      nil -> insert(attempt_id, attrs)
      existing -> existing_result(existing, attrs)
    end
  end

  defp insert(attempt_id, attrs) do
    with work_item when not is_nil(work_item) <- WorkItems.get(attrs[:work_item_id]),
         :ok <- active_mission(work_item),
         :ok <- expected_version(work_item, attrs[:expected_work_item_version]),
         context_bundle when not is_nil(context_bundle) <-
           ContextBundles.get(attrs[:context_bundle_id]),
         :ok <- same_work_item(context_bundle, work_item),
         {:ok, role_binding} <- role_binding(attrs[:role_binding_id], work_item),
         {:ok, caused_by} <- caused_by(attrs[:caused_by_attempt_id], work_item) do
      create_attrs =
        attrs
        |> Map.put(:attempt_id, attempt_id)
        |> Map.put(:work_item_id, work_item.id)
        |> Map.put(:role_binding_id, role_binding && role_binding.id)
        |> Map.put(:context_bundle_id, context_bundle.id)
        |> Map.put(:caused_by_attempt_id, caused_by && caused_by.id)
        |> Map.put(:state, "queued")
        |> Map.put(:context_digest, context_bundle.digest)
        |> Map.put(:usage, %{})
        |> Map.put(:provenance, provenance(attrs, role_binding))

      case create_attrs |> Attempt.create_changeset() |> Repo.insert() do
        {:ok, attempt} -> {:created, preload(attempt)}
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      nil -> Repo.rollback(:unknown_attempt_reference)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp existing_result(existing, attrs) do
    existing = preload(existing)

    if same_logical_attempt?(existing, attrs) do
      {:existing, existing}
    else
      Repo.rollback({:attempt_conflict, existing.attempt_id})
    end
  end

  defp same_logical_attempt?(attempt, attrs) do
    matches = [
      {:work_item_id, attempt.work_item.work_item_id},
      {:context_bundle_id, attempt.context_bundle.context_bundle_id},
      {:executor_kind, attempt.executor_kind},
      {:provider, attempt.provider},
      {:profile, attempt.profile},
      {:recipe_version, attempt.recipe_version},
      {:expected_work_item_version, attempt.expected_work_item_version},
      {:oban_job_id, attempt.oban_job_id},
      {:workflow_run_id, attempt.workflow_run_id},
      {:role_binding_id, attempt.role_binding && attempt.role_binding.binding_id},
      {:caused_by_attempt_id, attempt.caused_by_attempt && attempt.caused_by_attempt.attempt_id}
    ]

    Enum.all?(matches, fn {key, existing} ->
      not Map.has_key?(attrs, key) or attrs[key] == existing
    end)
  end

  defp existing_by_job(nil), do: nil
  defp existing_by_job(job_id), do: Repo.get_by(Attempt, oban_job_id: job_id)

  defp expected_version(_work_item, nil), do: {:error, :expected_work_item_version_required}
  defp expected_version(%{version: version}, version), do: :ok

  defp expected_version(%{version: observed}, expected) do
    {:error, {:stale_work_item, %{expected: expected, observed: observed}}}
  end

  defp active_mission(%{mission: %{status: "active"}}), do: :ok
  defp active_mission(_work_item), do: {:error, :mission_archived}

  defp same_work_item(%{work_item_id: work_item_id}, %{id: work_item_id}), do: :ok
  defp same_work_item(_context_bundle, _work_item), do: {:error, :context_work_item_mismatch}

  defp role_binding(nil, _work_item), do: {:ok, nil}

  defp role_binding(binding_id, work_item) do
    case RoleBindings.get(binding_id) do
      nil ->
        {:error, {:unknown_role_binding, binding_id}}

      %{lifecycle: "active", mission_id: mission_id} = binding
      when mission_id == work_item.mission_id ->
        {:ok, binding}

      %{lifecycle: lifecycle} when lifecycle != "active" ->
        {:error, :role_binding_retired}

      _other ->
        {:error, :role_binding_mission_mismatch}
    end
  end

  defp caused_by(nil, _work_item), do: {:ok, nil}

  defp caused_by(attempt_id, work_item) do
    case get(attempt_id) do
      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      %{work_item_id: work_item_id} = attempt when work_item_id == work_item.id ->
        if Attempt.terminal?(attempt),
          do: {:ok, attempt},
          else: {:error, {:attempt_nonterminal, attempt.state}}

      _other ->
        {:error, :caused_by_work_item_mismatch}
    end
  end

  defp provenance(attrs, role_binding) do
    normalize(attrs[:provenance] || %{})
    |> Map.put("executor", %{
      "kind" => to_string(attrs[:executor_kind]),
      "provider" => attrs[:provider],
      "profile" => attrs[:profile],
      "recipe_version" => attrs[:recipe_version]
    })
    |> Map.put(
      "role_binding",
      if(role_binding, do: RoleBindings.attempt_provenance(role_binding), else: nil)
    )
  end

  defp ensure_refs_match!(attempt, refs) do
    Enum.each([:oban_job_id, :workflow_run_id], fn key ->
      if Map.has_key?(refs, key) and not is_nil(Map.get(attempt, key)) and
           Map.get(attempt, key) != refs[key] do
        Repo.rollback({:attempt_dispatch_conflict, key})
      end
    end)
  end

  defp bind_missing_refs(attempt, refs) do
    attrs =
      refs
      |> Map.take([:oban_job_id, :workflow_run_id])
      |> Enum.reject(fn {key, _value} -> not is_nil(Map.get(attempt, key)) end)
      |> Map.new()

    if attrs == %{} do
      attempt
    else
      attrs =
        Map.merge(attrs, %{
          state: "running",
          started_at: attempt.started_at
        })

      update_or_rollback(Attempt.start_changeset(attempt, attrs))
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, attempt} -> attempt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp preload(nil), do: nil

  defp preload(attempt) do
    Repo.preload(attempt, [
      :work_item,
      :role_binding,
      :context_bundle,
      :caused_by_attempt,
      work_item: :mission,
      context_bundle: [:artifact, :mission, :work_item]
    ])
  end

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap_attempt({:ok, attempt}), do: {:ok, preload(attempt)}
  defp unwrap_attempt({:error, reason}), do: {:error, reason}

  defp atomize(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize(%{__struct__: _} = struct), do: normalize(Map.from_struct(struct))

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value) when value in [true, false, nil], do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp normalize_map_fields(attrs) do
    Enum.reduce(
      [:provider_continuation, :usage, :outcome, :error_details, :provenance],
      attrs,
      fn key, normalized ->
        if is_map(normalized[key]),
          do: Map.put(normalized, key, normalize(normalized[key])),
          else: normalized
      end
    )
  end
end
