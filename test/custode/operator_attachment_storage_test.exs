defmodule Custode.OperatorAttachmentStorageTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Operator.{Attachment, Attachments}
  alias Custode.{OperatorMessage, Repo, Uploads}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    routine = routine_fixture!(tmp_workspace!())
    actor = %{kind: :operator, id: uid("image-owner")}
    %{routine: routine, actor: actor}
  end

  test "upload returns owned metadata and read returns exact bytes without paths", ctx do
    assert {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    assert image.agent_id == ctx.routine.id
    assert image.byte_count == byte_size(@png)
    assert image.media_type == "image/png"
    assert image.sha256 == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
    assert {:ok, _, _} = DateTime.from_iso8601(image.created_at)
    assert image.retention =~ "Active messages"
    refute Map.has_key?(image, :path)
    refute Map.has_key?(image, :workspace)
    refute Map.has_key?(image, :owner_id)
    assert {:ok, read} = Attachments.read(ctx.actor, image.attachment_id)
    assert Map.delete(read, :data_base64) == image
    assert Base.decode64!(read.data_base64) == @png

    row = row(image)
    assert Path.basename(row.path) =~ ~r/^attachment-[a-z0-9-]+\.png$/
    assert Path.dirname(row.path) == Path.join(Path.expand(ctx.routine.workspace), "uploads")
  end

  test "concurrent identical uploads deduplicate within owner and target", ctx do
    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
        end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, {:ok, image}} -> image.attachment_id end)

    assert length(Enum.uniq(results)) == 1

    assert {:ok, other} =
             Attachments.upload(
               %{ctx.actor | id: uid("other")},
               ctx.routine.id,
               "image/png",
               @png
             )

    refute other.attachment_id in results
    assert length(File.ls!(Path.join(ctx.routine.workspace, "uploads"))) == 2
  end

  test "only authenticated operators can upload, retrieve or resolve", ctx do
    for actor <- [
          nil,
          %{kind: :operator},
          %{kind: :operator, id: ""},
          %{kind: :routine, id: ctx.routine.id}
        ] do
      assert {:error, :human_identity_required} =
               Attachments.upload(actor, ctx.routine.id, "image/png", @png)

      assert {:error, :human_identity_required} =
               Attachments.upload_file(actor, ctx.routine.id, "/missing", "image.png")

      assert {:error, :human_identity_required} = Attachments.read(actor, "missing")

      assert {:error, :human_identity_required} =
               Attachments.resolve(actor, "missing", ctx.routine.id)
    end
  end

  test "resolution requires a transaction, exact owner and exact target", ctx do
    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)

    assert {:error, :transaction_required} =
             Attachments.resolve(ctx.actor, image.attachment_id, ctx.routine.id)

    assert {:error, :attachment_forbidden} =
             Attachments.read(%{ctx.actor | id: "another"}, image.attachment_id)

    assert {:error, :attachment_not_found} = Attachments.read(ctx.actor, Ecto.UUID.generate())
    assert {:error, :invalid_attachment} = Attachments.read(ctx.actor, nil)

    assert {:ok, :resolved} =
             Repo.transaction(
               fn ->
                 assert {:error, :attachment_target_mismatch} =
                          Attachments.resolve(ctx.actor, image.attachment_id, "another")

                 assert {:ok, path} =
                          Attachments.resolve(ctx.actor, image.attachment_id, ctx.routine.id)

                 assert path == row(image).path
                 :resolved
               end,
               mode: :immediate
             )
  end

  test "workspace changes invalidate old references and prevent cross-workspace dedup", ctx do
    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    put_env!(:routines, [%{ctx.routine | workspace: tmp_workspace!()}])

    assert {:error, :attachment_workspace_changed} =
             Attachments.read(ctx.actor, image.attachment_id)

    assert {:ok, {:error, :attachment_workspace_changed}} =
             Repo.transaction(
               fn ->
                 Attachments.resolve(ctx.actor, image.attachment_id, ctx.routine.id)
               end,
               mode: :immediate
             )

    assert {:ok, new} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    refute new.attachment_id == image.attachment_id
  end

  test "bounded format recognition refuses unsupported, mismatched and oversized data", ctx do
    assert {:error, :unsupported_media_type} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/svg+xml", "<svg/>")

    assert {:error, :invalid_image} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/jpeg", @png)

    assert {:error, :invalid_image} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/png", "")

    assert {:error, :no_such_routine} =
             Attachments.upload(ctx.actor, uid("missing"), "image/png", @png)

    bytes = @png <> :binary.copy("x", Attachments.max_bytes())

    assert {:error, :too_large} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/png", bytes)

    tmp = Path.join(ctx.routine.workspace, "large.png")
    File.write!(tmp, bytes)

    assert {:error, :too_large} =
             Attachments.upload_file(ctx.actor, ctx.routine.id, tmp, "photo.png")
  end

  test "the upload boundary accepts exactly the configured byte limit", ctx do
    bytes = @png <> :binary.copy("x", Attachments.max_bytes() - byte_size(@png))
    assert {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", bytes)
    assert image.byte_count == Attachments.max_bytes()
    assert {:ok, read} = Attachments.read(ctx.actor, image.attachment_id)
    assert Base.decode64!(read.data_base64) == bytes
  end

  test "the temporary-file adapter uses bounded identification and server-owned filenames", ctx do
    tmp = Path.join(ctx.routine.workspace, "input")
    File.write!(tmp, @png)

    assert {:ok, image} =
             Attachments.upload_file(ctx.actor, ctx.routine.id, tmp, "../../somewhere.PNG")

    assert Path.basename(row(image).path) =~ ~r/^attachment-/

    assert {:error, :unsupported_media_type} =
             Attachments.upload_file(ctx.actor, ctx.routine.id, tmp, "x.exe")

    File.ln_s!(tmp, tmp <> "-link")

    assert {:error, :unsafe_path} =
             Attachments.upload_file(ctx.actor, ctx.routine.id, tmp <> "-link", "x.png")
  end

  test "changed, absent and symlinked bytes are refused; reupload creates a fresh reference",
       ctx do
    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    path = row(image).path
    File.write!(path, :binary.copy("x", byte_size(@png)))
    assert {:error, :attachment_unavailable} = Attachments.read(ctx.actor, image.attachment_id)
    assert {:ok, repaired} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    refute repaired.attachment_id == image.attachment_id
    assert {:error, :attachment_expired} = Attachments.read(ctx.actor, image.attachment_id)
    assert File.read!(path) == :binary.copy("x", byte_size(@png))

    repaired_path = row(repaired).path
    File.rm!(repaired_path)
    assert {:error, :attachment_unavailable} = Attachments.read(ctx.actor, repaired.attachment_id)
    assert {:ok, replacement} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    refute replacement.attachment_id == repaired.attachment_id
    assert {:error, :attachment_expired} = Attachments.read(ctx.actor, repaired.attachment_id)
    path = row(replacement).path
    File.rm!(path)
    outside = Path.join(ctx.routine.workspace, "outside.png")
    File.write!(outside, @png)
    File.ln_s!(outside, path)

    assert {:error, :attachment_unavailable} =
             Attachments.read(ctx.actor, replacement.attachment_id)

    assert Uploads.path(ctx.routine.id, path) == :error
    assert {:ok, fresh} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    refute fresh.attachment_id == replacement.attachment_id
    assert File.read_link(path) == {:ok, outside}
    assert File.read!(outside) == @png
  end

  test "a symlinked workspace or upload directory cannot redirect a write", ctx do
    outside = tmp_workspace!()
    File.ln_s!(outside, Path.join(ctx.routine.workspace, "uploads"))

    assert {:error, :unsafe_path} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)

    assert File.ls!(outside) == ["inbox"]
    link = Path.join(ctx.routine.workspace, "workspace-link")
    File.ln_s!(outside, link)
    put_env!(:routines, [%{ctx.routine | workspace: link}])

    assert {:error, :unsafe_path} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)

    assert File.ls!(outside) == ["inbox"]
  end

  test "pruning retains active messages and ages terminal links from their latest update", ctx do
    for status <- ~w(queued executing waiting_for_input waiting_for_approval) do
      {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png <> status)
      old = age(row(image), 90)
      message!(image, ctx, status, 90)
      Attachments.prune(30)
      assert Repo.get!(Attachment, old.id).deleted_at == nil
      assert File.exists?(old.path)
    end

    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png <> "terminal")
    old = age(row(image), 90)
    message = message!(image, ctx, "completed", 1)
    Attachments.prune(30)
    assert File.exists?(old.path)
    age(message, 31)
    Attachments.prune(30)
    refute File.exists?(old.path)
    assert Repo.get!(Attachment, old.id).deleted_at
    assert {:error, :attachment_expired} = Attachments.read(ctx.actor, image.attachment_id)

    assert {:ok, new} =
             Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png <> "terminal")

    refute new.attachment_id == image.attachment_id
  end

  test "abandoned uploads expire; tombstones hide files and retry safe unlinking", ctx do
    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    old = age(row(image), 31)
    Attachments.prune(30)
    assert Repo.get!(Attachment, old.id).deleted_at
    refute File.exists?(old.path)
    File.write!(old.path, @png)
    assert Uploads.path(ctx.routine.id, old.path) == :error
    assert MapSet.member?(Attachments.protected_paths(), old.path)
    Attachments.prune(30)
    refute File.exists?(old.path)
  end

  test "pruning cannot unlink through a substituted directory or a stored path escape", ctx do
    {:ok, image} = Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png)
    old = age(row(image), 31)
    moved = Path.join(ctx.routine.workspace, "moved-uploads")
    File.rename!(Path.dirname(old.path), moved)
    File.ln_s!(moved, Path.dirname(old.path))
    Attachments.prune(30)
    assert File.exists?(Path.join(moved, Path.basename(old.path)))
    assert Repo.get!(Attachment, old.id).deleted_at

    outside = Path.join(ctx.routine.workspace, "outside.png")
    File.write!(outside, @png)
    old |> Ecto.Changeset.change(path: outside) |> Repo.update!()
    Attachments.prune(30)
    assert File.read!(outside) == @png
  end

  test "legacy prompt paths including spaces remain pinned while the message is active", ctx do
    path = Path.join([ctx.routine.workspace, "uploads", "old image.png"])

    message!(
      %{attachment_id: nil},
      ctx,
      "waiting_for_input",
      90,
      Attachments.compose("inspect", [path])
    )

    assert MapSet.member?(Attachments.protected_paths(), path)
  end

  defp row(image), do: Repo.get_by!(Attachment, attachment_id: image.attachment_id)

  defp age(row, days) do
    old = DateTime.add(DateTime.utc_now(), -days, :day)
    row |> Ecto.Changeset.change(inserted_at: old, updated_at: old) |> Repo.update!()
  end

  defp message!(image, ctx, status, days, prompt \\ "inspect") do
    old = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.insert!(%OperatorMessage{
      message_id: uid("image-message"),
      caller_kind: "operator",
      caller_id: ctx.actor.id,
      transport: "test",
      target_agent_id: ctx.routine.id,
      attachment_id: image.attachment_id,
      idempotency_key: uid("image-request"),
      provider_correlation_id: uid("image-correlation"),
      prompt_hash: "fixture",
      prompt: prompt,
      status: status,
      inserted_at: old,
      updated_at: old
    })
  end
end
