defmodule Custode.Operator.Attachments do
  @moduledoc """
  Bounded operator image storage shared by the UI and MCP.

  Public references bind an immutable file to its uploader, routine and current
  workspace. Image signatures identify the supported formats; they do not fully
  decode or certify an image. Local processes with workspace access can still
  replace files, so resolution checks the size and complete content digest.

  Prompt admission resolves a reference inside the same immediate transaction
  that inserts its durable message. Retention checks use that transaction too:
  active messages pin images, then terminal messages receive the normal retention
  window. Expiration commits a tombstone before unlinking; failed unlinks are
  retried on the next prune. Database and filesystem writes are not one atomic
  operation. An interrupted upload may leave an unreferenced file for the janitor.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Operator.Attachment
  alias Custode.{OperatorMessage, Repo, Routine}

  @image_types ~w(.png .jpg .jpeg .gif .webp)
  @max_bytes 10_000_000
  @active_statuses ~w(queued executing waiting_for_input waiting_for_approval)
  @retention "Active messages retain the image. Otherwise the configured upload retention applies " <>
               "from upload or latest message update (30 days by default). Expired references cannot be reused."
  @extensions %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp"
  }

  def image_types, do: @image_types
  def max_bytes, do: @max_bytes

  @doc "Store one bounded image; live identical uploads by the same owner and target reuse a reference."
  def upload(actor, agent_id, media_type, bytes) do
    with :ok <- human(actor),
         :ok <- validate_image(media_type, bytes) do
      transaction(fn -> upload_locked(actor, agent_id, media_type, bytes) end)
    end
  end

  @doc "The UI adapter for a temporary upload; client filenames select a format, never a path."
  def upload_file(actor, agent_id, tmp_path, client_name) do
    with :ok <- human(actor),
         {:ok, media_type} <- media_type(client_name),
         {:ok, bytes} <- bounded_read(tmp_path) do
      upload(actor, agent_id, media_type, bytes)
    end
  end

  @doc "Read an owned reference as base64, serialized against expiration. Never exposes a path."
  def read(actor, attachment_id) do
    with :ok <- human(actor) do
      transaction(fn -> read_locked(actor, attachment_id) end)
    end
  end

  @doc "Resolve inside the caller's immediate message-admission transaction."
  def resolve(actor, attachment_id, target_agent_id) do
    with :ok <- human(actor),
         :ok <- require_transaction(),
         {:ok, row} <- owned(actor, attachment_id),
         :ok <- target(row, target_agent_id),
         :ok <- current_workspace(row),
         {:ok, _bytes} <- contents(row) do
      {:ok, row.path}
    end
  end

  @doc "Expire unpinned images and retry unlinking tombstones. Returns newly expired references."
  def prune(days) when is_integer(days) and days >= 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    case transaction(fn -> {:ok, retire_locked(cutoff)} end) do
      {:ok, count} ->
        Repo.all(from(a in Attachment, where: not is_nil(a.deleted_at)))
        |> Enum.each(&unlink_retired/1)

        count

      {:error, _reason} ->
        0
    end
  end

  @doc "Paths the legacy mtime janitor must not remove, including managed tombstones."
  def protected_paths do
    managed = Repo.all(from(a in Attachment, select: a.path))

    legacy =
      Repo.all(
        from(m in OperatorMessage,
          where: is_nil(m.attachment_id) and m.status in ^@active_statuses,
          select: m.prompt
        )
      )
      |> Enum.flat_map(&prompt_paths/1)

    MapSet.new(managed ++ legacy)
  end

  @doc "A regular file directly inside a real workspace/uploads directory, with no final symlinks."
  def safe_file?(workspace, path) when is_binary(workspace) and is_binary(path) do
    with {:ok, dir} <- upload_dir(workspace, :existing),
         true <- Path.dirname(path) == dir,
         {:ok, %{type: :regular}} <- File.lstat(path) do
      true
    else
      _unsafe -> false
    end
  end

  def safe_file?(_workspace, _path), do: false

  @doc "The dashboard must not serve a managed file whose expiration already committed."
  def retired_path?(path) do
    Repo.exists?(from(a in Attachment, where: a.path == ^path and not is_nil(a.deleted_at)))
  end

  @doc "Strict legacy path adapter. New message surfaces use upload_file/4 and durable references."
  def store!(%{workspace: workspace}, tmp_path, client_name) do
    with {:ok, media_type} <- media_type(client_name),
         {:ok, bytes} <- bounded_read(tmp_path),
         :ok <- validate_image(media_type, bytes),
         {:ok, dir} <- upload_dir(workspace, :create),
         path = Path.join(dir, digest(bytes) <> Map.fetch!(@extensions, media_type)),
         :ok <- store_legacy(path, bytes) do
      path
    else
      {:error, reason} -> raise ArgumentError, error_message(reason)
    end
  end

  @doc "The provider receives the text followed by its server-resolved image path."
  def compose(text, []), do: text

  def compose(text, paths) do
    [String.trim(text) | Enum.map(paths, &"attached image: #{&1} -- Read it before answering")]
    |> Enum.join("\n")
    |> String.trim()
  end

  def error_message(:human_identity_required),
    do: "An authenticated operator identity is required."

  def error_message(:no_such_routine), do: "The target agent is not configured."
  def error_message(:unsupported_media_type), do: "Choose a PNG, JPEG, GIF or WebP image."
  def error_message(:invalid_image), do: "The image header does not match its declared format."
  def error_message(:too_large), do: "The image exceeds the 10,000,000-byte limit."
  def error_message(:invalid_attachment), do: "Provide a valid attachment reference."
  def error_message(:attachment_not_found), do: "The attachment reference was not found."
  def error_message(:attachment_forbidden), do: "This attachment belongs to another operator."
  def error_message(:attachment_target_mismatch), do: "This attachment belongs to another agent."

  def error_message(:attachment_workspace_changed),
    do: "The agent's workspace changed. Upload the image again."

  def error_message(:attachment_expired), do: "This attachment expired. Upload the image again."

  def error_message(:attachment_unavailable),
    do: "The stored image is missing or changed. Upload it again."

  def error_message(:unsafe_path),
    do: "The image storage path is not a regular file or directory."

  def error_message(:transaction_required),
    do: "Attachment resolution requires message admission."

  def error_message(_reason), do: "The image could not be stored or retrieved. Try again."

  defp upload_locked(actor, agent_id, media_type, bytes) do
    with {:ok, routine} <- routine(agent_id),
         {:ok, dir} <- upload_dir(routine.workspace, :create) do
      store_managed(actor.id, routine.id, dir, media_type, bytes)
    end
  end

  defp read_locked(actor, attachment_id) do
    with {:ok, row} <- owned(actor, attachment_id),
         :ok <- current_workspace(row),
         {:ok, bytes} <- contents(row) do
      {:ok, Map.put(public(row), :data_base64, Base.encode64(bytes))}
    end
  end

  defp human(%{kind: :operator, id: id}) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp human(_actor), do: {:error, :human_identity_required}

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
  end

  defp routine(agent_id) when is_binary(agent_id) do
    case Routine.get(agent_id) do
      nil -> {:error, :no_such_routine}
      value -> {:ok, value}
    end
  end

  defp routine(_agent_id), do: {:error, :no_such_routine}

  defp transaction(fun) do
    if Repo.in_transaction?() do
      {:error, :storage_failed}
    else
      Repo.transaction(fn -> unwrap(fun.()) end, mode: :immediate)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp owned(actor, id) when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 128 do
    case Repo.get_by(Attachment, attachment_id: id) do
      nil -> {:error, :attachment_not_found}
      %{owner_id: owner} when owner != actor.id -> {:error, :attachment_forbidden}
      %{deleted_at: deleted} when not is_nil(deleted) -> {:error, :attachment_expired}
      row -> {:ok, row}
    end
  end

  defp owned(_actor, _id), do: {:error, :invalid_attachment}
  defp target(%{agent_id: target}, target), do: :ok
  defp target(_row, _target), do: {:error, :attachment_target_mismatch}

  defp current_workspace(row) do
    with {:ok, routine} <- routine(row.agent_id) do
      if Path.expand(routine.workspace) == row.workspace,
        do: :ok,
        else: {:error, :attachment_workspace_changed}
    end
  end

  defp store_managed(owner, agent_id, dir, media_type, bytes) do
    attrs = %{
      owner_id: owner,
      agent_id: agent_id,
      workspace: Path.dirname(dir),
      sha256: digest(bytes)
    }

    existing =
      Repo.one(
        from(a in Attachment,
          where:
            a.owner_id == ^owner and a.agent_id == ^agent_id and
              a.workspace == ^attrs.workspace and a.sha256 == ^attrs.sha256 and
              is_nil(a.deleted_at)
        )
      )

    case existing do
      nil -> insert_image(attrs, dir, media_type, bytes)
      row -> reuse_or_replace(row, attrs, dir, media_type, bytes)
    end
  end

  defp reuse_or_replace(row, attrs, dir, media_type, bytes) do
    case contents(row) do
      {:ok, _bytes} ->
        {:ok, public(row)}

      {:error, :attachment_unavailable} ->
        row |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
        insert_image(attrs, dir, media_type, bytes)
    end
  end

  defp insert_image(attrs, dir, media_type, bytes) do
    id = Ecto.UUID.generate()
    path = Path.join(dir, "attachment-" <> id <> Map.fetch!(@extensions, media_type))

    with :ok <- exclusive_write(path, bytes) do
      attrs =
        Map.merge(attrs, %{
          attachment_id: id,
          path: path,
          media_type: media_type,
          byte_count: byte_size(bytes)
        })

      case attrs |> Attachment.changeset() |> Repo.insert() do
        {:ok, row} ->
          {:ok, public(row)}

        {:error, _changeset} ->
          File.rm(path)
          {:error, :storage_failed}
      end
    end
  end

  defp public(row) do
    %{
      attachment_id: row.attachment_id,
      agent_id: row.agent_id,
      media_type: row.media_type,
      byte_count: row.byte_count,
      sha256: row.sha256,
      retention: @retention,
      created_at: DateTime.to_iso8601(row.inserted_at)
    }
  end

  defp contents(row) do
    if safe_file?(row.workspace, row.path) do
      with {:ok, bytes} <- bounded_read(row.path),
           true <- byte_size(bytes) == row.byte_count and digest(bytes) == row.sha256 do
        {:ok, bytes}
      else
        _unavailable -> {:error, :attachment_unavailable}
      end
    else
      {:error, :attachment_unavailable}
    end
  end

  defp validate_image(media_type, bytes) when is_binary(bytes) do
    cond do
      not Map.has_key?(@extensions, media_type) -> {:error, :unsupported_media_type}
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      signature(bytes) != media_type -> {:error, :invalid_image}
      true -> :ok
    end
  end

  defp validate_image(_media_type, _bytes), do: {:error, :invalid_image}
  defp signature(<<137, "PNG\r\n", 26, "\n", _rest::binary>>), do: "image/png"
  defp signature(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"
  defp signature(<<"GIF87a", _rest::binary>>), do: "image/gif"
  defp signature(<<"GIF89a", _rest::binary>>), do: "image/gif"
  defp signature(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  defp signature(_bytes), do: nil

  defp media_type(name) when is_binary(name) do
    case name |> Path.extname() |> String.downcase() do
      ".png" -> {:ok, "image/png"}
      ext when ext in [".jpg", ".jpeg"] -> {:ok, "image/jpeg"}
      ".gif" -> {:ok, "image/gif"}
      ".webp" -> {:ok, "image/webp"}
      _extension -> {:error, :unsupported_media_type}
    end
  end

  defp media_type(_name), do: {:error, :unsupported_media_type}

  defp bounded_read(path) when is_binary(path) do
    with {:ok, stat} <- File.lstat(path),
         :ok <- readable(stat),
         {:ok, result} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      bounded_result(result)
    else
      {:error, reason} when reason in [:too_large, :unsafe_path] -> {:error, reason}
      _unavailable -> {:error, :attachment_unavailable}
    end
  end

  defp bounded_read(_path), do: {:error, :unsafe_path}
  defp readable(%{type: :regular, size: size}) when size > @max_bytes, do: {:error, :too_large}
  defp readable(%{type: :regular}), do: :ok
  defp readable(_stat), do: {:error, :unsafe_path}

  defp bounded_result(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: {:error, :too_large}

  defp bounded_result(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp bounded_result(:eof), do: {:ok, ""}
  defp bounded_result(_other), do: {:error, :attachment_unavailable}

  defp upload_dir(workspace, mode) do
    workspace = Path.expand(workspace)
    dir = Path.join(workspace, "uploads")

    with :ok <- ensure_workspace(workspace, mode),
         :ok <- real_directory(workspace),
         :ok <- ensure_uploads(dir, mode),
         :ok <- real_directory(dir) do
      {:ok, dir}
    end
  end

  defp ensure_workspace(path, :create), do: file_result(File.mkdir_p(path))
  defp ensure_workspace(_path, :existing), do: :ok
  defp ensure_uploads(path, :create), do: file_result(File.mkdir(path))
  defp ensure_uploads(_path, :existing), do: :ok
  defp file_result(:ok), do: :ok
  defp file_result({:error, :eexist}), do: :ok
  defp file_result(_error), do: {:error, :unsafe_path}

  defp real_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _unsafe -> {:error, :unsafe_path}
    end
  end

  defp exclusive_write(path, bytes) do
    case File.write(path, bytes, [:binary, :exclusive]) do
      :ok -> :ok
      {:error, _reason} -> {:error, :storage_failed}
    end
  end

  defp store_legacy(path, bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        exclusive_write(path, bytes)

      {:ok, %{type: :regular}} ->
        if bounded_read(path) == {:ok, bytes}, do: :ok, else: {:error, :attachment_unavailable}

      _unsafe ->
        {:error, :unsafe_path}
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp retire_locked(cutoff) do
    candidates =
      Repo.all(from(a in Attachment, where: is_nil(a.deleted_at) and a.inserted_at < ^cutoff))

    now = DateTime.utc_now()

    Enum.count(candidates, fn row ->
      if unpinned?(row.attachment_id, cutoff) do
        row |> Ecto.Changeset.change(deleted_at: now) |> Repo.update!()
        true
      else
        false
      end
    end)
  end

  defp unpinned?(id, cutoff) do
    not Repo.exists?(
      from(m in OperatorMessage,
        where:
          m.attachment_id == ^id and (m.status in ^@active_statuses or m.updated_at >= ^cutoff)
      )
    )
  end

  defp unlink_retired(row) do
    if safe_file?(row.workspace, row.path), do: File.rm(row.path)
  end

  defp prompt_paths(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.flat_map(fn
      "attached image: " <> rest ->
        [String.replace_suffix(rest, " -- Read it before answering", "")]

      _line ->
        []
    end)
  end
end
