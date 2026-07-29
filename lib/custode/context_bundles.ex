defmodule Custode.ContextBundles do
  @moduledoc """
  Reproducible dossiers for Attempts.

  The database row holds stable identity and hashes. The normalized JSON body
  is an Artifact, keeping potentially large context out of SQLite.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Artifacts, ContextBundle, Repo, WorkItems}

  @components ~w(
    objective
    acceptance
    policy
    recipe
    prior_evidence
    external_revision
    workspace_revision
  )

  @spec get(String.t()) :: ContextBundle.t() | nil
  def get(context_bundle_id) do
    ContextBundle
    |> Repo.get_by(context_bundle_id: context_bundle_id)
    |> preload()
  end

  @spec list_for_work_item(String.t()) :: [ContextBundle.t()]
  def list_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        []

      work_item ->
        from(bundle in ContextBundle,
          where: bundle.work_item_id == ^work_item.id,
          order_by: [asc: bundle.version]
        )
        |> Repo.all()
        |> Enum.map(&preload/1)
    end
  end

  @doc """
  Persist a normalized ContextBundle body and metadata.

  Identical content for one WorkItem reuses the existing bundle. The caller
  may pass `:artifact_dir` to place the file in a specific durable tree.
  """
  def create(work_item_id, body, opts \\ []) when is_map(body) do
    normalized = normalize(body)

    with :ok <- validate_components(normalized),
         work_item when not is_nil(work_item) <- WorkItems.get(work_item_id) do
      digest = digest(normalized)
      insert_or_reuse(work_item, normalized, digest, opts)
    else
      nil -> {:error, {:unknown_work_item, work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Read and verify the file-backed body for a bundle."
  def body(%ContextBundle{} = bundle) do
    bundle = preload(bundle)

    with {:ok, encoded} <- File.read(bundle.artifact.location),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- digest(decoded) == bundle.digest do
      {:ok, decoded}
    else
      false -> {:error, :context_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def body(context_bundle_id) when is_binary(context_bundle_id) do
    case get(context_bundle_id) do
      nil -> {:error, {:unknown_context_bundle, context_bundle_id}}
      bundle -> body(bundle)
    end
  end

  @doc "Canonical digest of a full ContextBundle body."
  def digest(body) when is_map(body) do
    body
    |> normalize()
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "A digest per acceptance-sensitive ContextBundle component."
  def component_digests(body) when is_map(body) do
    normalized = normalize(body)
    Map.new(@components, fn key -> {key, digest_value(Map.fetch!(normalized, key))} end)
  end

  @spec render(ContextBundle.t()) :: map()
  def render(%ContextBundle{} = bundle) do
    bundle = preload(bundle)

    %{
      context_bundle_id: bundle.context_bundle_id,
      work_item_id: bundle.work_item.work_item_id,
      mission_id: bundle.mission.mission_id,
      artifact_id: bundle.artifact.artifact_id,
      version: bundle.version,
      digest: bundle.digest,
      component_digests: bundle.component_digests,
      provenance: bundle.provenance
    }
  end

  defp insert_or_reuse(work_item, body, digest, opts) do
    Repo.transaction(
      fn ->
        case get_by_digest(work_item.id, digest) do
          %ContextBundle{} = bundle -> {:existing, preload(bundle)}
          nil -> insert(work_item, body, digest, opts)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert(work_item, body, digest, opts) do
    provenance = normalize(Keyword.get(opts, :provenance, %{}))

    artifact_attrs = %{
      kind: "context_bundle",
      media_type: "application/json",
      provenance: provenance,
      retention: normalize(Keyword.get(opts, :retention, %{}))
    }

    artifact =
      case Artifacts.put(
             work_item.work_item_id,
             Jason.encode!(body),
             artifact_attrs,
             artifact_dir: Keyword.get(opts, :artifact_dir, default_dir())
           ) do
        {:ok, artifact} -> artifact
        {:error, reason} -> Repo.rollback(reason)
      end

    attrs = %{
      context_bundle_id: Ecto.UUID.generate(),
      work_item_id: work_item.id,
      mission_id: work_item.mission_id,
      artifact_id: artifact.id,
      version: next_version(work_item.id),
      digest: digest,
      component_digests: component_digests(body),
      provenance: Map.put_new(provenance, "work_item_version", work_item.version)
    }

    case attrs |> ContextBundle.create_changeset() |> Repo.insert() do
      {:ok, bundle} -> {:created, preload(bundle)}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp get_by_digest(work_item_id, digest) do
    Repo.get_by(ContextBundle, work_item_id: work_item_id, digest: digest)
  end

  defp next_version(work_item_id) do
    (Repo.aggregate(
       from(bundle in ContextBundle, where: bundle.work_item_id == ^work_item_id),
       :max,
       :version
     ) || 0) + 1
  end

  defp validate_components(body) do
    case Enum.reject(@components, &Map.has_key?(body, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_context_components, missing}}
    end
  end

  defp default_dir do
    Custode.Home.resolve_in(&Custode.Home.data_dir/0, "artifacts/context_bundles")
  end

  defp digest_value(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp normalize(%{__struct__: _} = struct), do: normalize(Map.from_struct(struct))

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value) when value in [true, false, nil], do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp preload(nil), do: nil
  defp preload(bundle), do: Repo.preload(bundle, [:work_item, :mission, :artifact])
end
