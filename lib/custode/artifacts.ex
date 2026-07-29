defmodule Custode.Artifacts do
  @moduledoc """
  Artifact metadata and the narrow file-backed writer used by ContextBundles.

  Bodies stay on disk under the Custode data directory. SQLite stores only
  queryable identity, provenance, digest, location, and retention metadata.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Artifact, Attempts, Repo, WorkItems}

  @spec get(String.t()) :: Artifact.t() | nil
  def get(artifact_id) do
    Artifact
    |> Repo.get_by(artifact_id: artifact_id)
    |> preload()
  end

  @spec get_by_external_identity(String.t()) :: Artifact.t() | nil
  def get_by_external_identity(external_identity) when is_binary(external_identity) do
    Artifact
    |> Repo.get_by(external_identity: external_identity)
    |> preload()
  end

  @spec list_for_work_item(String.t()) :: [Artifact.t()]
  def list_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        []

      work_item ->
        from(artifact in Artifact,
          where: artifact.work_item_id == ^work_item.id,
          order_by: [asc: artifact.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&preload/1)
    end
  end

  @doc """
  Store a body on disk and create its Artifact metadata.

  `:artifact_dir` may override the default data directory for a caller-owned
  workspace or a test. The digest and size always come from the bytes written.
  """
  def put(work_item_id, body, attrs \\ %{}, opts \\ [])
      when is_binary(body) and (is_map(attrs) or is_list(attrs)) do
    attrs = atomize(attrs)
    digest = digest(body)
    artifact_id = attrs[:artifact_id] || Ecto.UUID.generate()
    directory = Keyword.get(opts, :artifact_dir, default_dir())
    extension = attrs[:extension] || extension_for(attrs[:media_type])
    path = Path.join(directory, artifact_id <> extension)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(path, body, [:exclusive]) do
      case create(
             Map.merge(attrs, %{
               artifact_id: artifact_id,
               work_item_id: work_item_id,
               digest: digest,
               location: Path.expand(path),
               size_bytes: byte_size(body)
             })
           ) do
        {:ok, artifact} ->
          {:ok, artifact}

        {:error, _reason} = error ->
          File.rm(path)
          error
      end
    else
      {:error, reason} ->
        {:error, {:artifact_write, reason}}
    end
  end

  @doc "Create metadata for an existing file or stable external artifact."
  def create(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize(attrs)

    with work_item when not is_nil(work_item) <- WorkItems.get(attrs[:work_item_id]),
         :ok <- active_mission(work_item),
         {:ok, producer} <- producer(attrs[:producer_attempt_id], work_item),
         create_attrs <-
           attrs
           |> Map.put_new(:artifact_id, Ecto.UUID.generate())
           |> Map.put(:work_item_id, work_item.id)
           |> Map.put(:mission_id, work_item.mission_id)
           |> Map.put(:producer_attempt_id, producer && producer.id)
           |> Map.put_new(:provenance, %{})
           |> Map.put_new(:retention, %{}),
         {:ok, artifact} <- create_attrs |> Artifact.create_changeset() |> Repo.insert() do
      {:ok, preload(artifact)}
    else
      nil -> {:error, {:unknown_work_item, attrs[:work_item_id]}}
      {:error, _reason} = error -> error
    end
  end

  @spec render(Artifact.t()) :: map()
  def render(%Artifact{} = artifact) do
    artifact = preload(artifact)

    %{
      artifact_id: artifact.artifact_id,
      producer_attempt_id: artifact.producer_attempt && artifact.producer_attempt.attempt_id,
      work_item_id: artifact.work_item.work_item_id,
      mission_id: artifact.mission.mission_id,
      kind: artifact.kind,
      provenance: artifact.provenance,
      external_identity: artifact.external_identity,
      digest: artifact.digest,
      media_type: artifact.media_type,
      location: artifact.location,
      size_bytes: artifact.size_bytes,
      retention: artifact.retention,
      expires_at: artifact.expires_at
    }
  end

  def digest(body) when is_binary(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  defp active_mission(%{mission: %{status: "active"}}), do: :ok
  defp active_mission(_work_item), do: {:error, :mission_archived}

  defp producer(nil, _work_item), do: {:ok, nil}

  defp producer(attempt_id, work_item) do
    case Attempts.get(attempt_id) do
      nil ->
        {:error, {:unknown_attempt, attempt_id}}

      %{work_item_id: work_item_id} = attempt when work_item_id == work_item.id ->
        {:ok, attempt}

      _other ->
        {:error, :producer_work_item_mismatch}
    end
  end

  defp default_dir do
    Custode.Home.resolve_in(&Custode.Home.data_dir/0, "artifacts")
  end

  defp extension_for("application/json"), do: ".json"
  defp extension_for("text/markdown"), do: ".md"
  defp extension_for("text/plain"), do: ".txt"
  defp extension_for(_media_type), do: ".bin"

  defp preload(nil), do: nil

  defp preload(artifact) do
    Repo.preload(artifact, [:producer_attempt, :work_item, :mission])
  end

  defp atomize(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end
end
