defmodule Custode.OperatorAttachmentMessagesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{Agents, OperatorMessage, OperatorMessages, Repo, Routine}
  alias Custode.Operator.{Actions, Attachment, Attachments}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    routine = routine_fixture!(tmp_workspace!(), %{cron: :manual})
    actor = %{kind: :operator, id: uid("attachment-operator")}
    {:ok, attachment} = Attachments.upload(actor, routine.id, "image/png", @png)
    %{routine: routine, actor: actor, attachment: attachment}
  end

  defp opts(ctx, key \\ "attachment-request") do
    [actor: ctx.actor, attachment_id: ctx.attachment.attachment_id, idempotency_key: key]
  end

  test "concurrent image-only retries pin one image and deliver once after commit", ctx do
    parent = self()

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          OperatorMessages.submit(ctx.routine.id, "  ", opts(ctx), fn message ->
            refute Repo.in_transaction?()
            send(parent, {:delivered_image, message})
            {:ok, :queued}
          end)
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert_receive {:delivered_image, message}
    refute_receive {:delivered_image, _}, 100
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :duplicate}, &1)) == 7
    assert message.attachment_id == ctx.attachment.attachment_id
    assert message.prompt =~ "attached image: "
    assert Repo.get!(OperatorMessage, message.id).attachment_id == message.attachment_id
    assert OperatorMessages.public(message).attachment_id == message.attachment_id
    assert OperatorMessages.public_summary(message).attachment_id == message.attachment_id
  end

  test "changed text or attachment conflicts without another delivery", ctx do
    deliver = fn _ -> {:ok, :queued} end

    assert {:ok, _, :created} =
             OperatorMessages.submit(ctx.routine.id, "inspect", opts(ctx), deliver)

    assert {:error, :idempotency_conflict} =
             OperatorMessages.submit(ctx.routine.id, "publish", opts(ctx), deliver)

    assert {:error, :idempotency_conflict} =
             OperatorMessages.submit(
               ctx.routine.id,
               "inspect",
               Keyword.delete(opts(ctx), :attachment_id),
               deliver
             )

    assert {:error, :idempotency_conflict} =
             OperatorMessages.submit(
               ctx.routine.id,
               "inspect",
               Keyword.put(opts(ctx), :attachment_id, Ecto.UUID.generate()),
               deliver
             )
  end

  test "text shaped like an attachment fingerprint is not the same request", ctx do
    text = "attachment-v1:" <> Jason.encode!(["inspect", ctx.attachment.attachment_id])
    plain_opts = Keyword.delete(opts(ctx), :attachment_id)

    assert {:ok, _, :created} =
             OperatorMessages.submit(ctx.routine.id, text, plain_opts, fn _ -> {:ok, :queued} end)

    assert {:error, :idempotency_conflict} =
             OperatorMessages.submit(ctx.routine.id, "inspect", opts(ctx), fn _ ->
               flunk("different request delivered")
             end)
  end

  test "a handled text-only conflict does not roll back its caller transaction", ctx do
    plain_opts = Keyword.delete(opts(ctx), :attachment_id)

    assert {:ok, _, :created} =
             OperatorMessages.submit(ctx.routine.id, "inspect", plain_opts, fn _ ->
               {:ok, :queued}
             end)

    assert {:ok, :caller_committed} =
             Repo.transaction(fn ->
               assert {:error, :idempotency_conflict} =
                        OperatorMessages.submit(ctx.routine.id, "different", plain_opts, fn _ ->
                          flunk("conflicting delivery")
                        end)

               :caller_committed
             end)
  end

  test "the retained receipt survives expired bytes and a workspace move", ctx do
    assert {:ok, message, :created} =
             OperatorMessages.submit(ctx.routine.id, "inspect", opts(ctx), fn _ ->
               {:ok, :queued}
             end)

    row = Repo.get_by!(Attachment, attachment_id: ctx.attachment.attachment_id)
    Repo.update!(Ecto.Changeset.change(row, deleted_at: DateTime.utc_now()))
    File.rm!(row.path)
    put_env!(:routines, [%{ctx.routine | workspace: tmp_workspace!()}])

    assert {:ok, duplicate, :duplicate} =
             OperatorMessages.submit(ctx.routine.id, " inspect ", opts(ctx), fn _ ->
               flunk("redelivered")
             end)

    assert duplicate.message_id == message.message_id
    assert duplicate.prompt == message.prompt

    assert {:error, _} =
             OperatorMessages.submit(ctx.routine.id, "inspect", opts(ctx, "new-request"), fn _ ->
               flunk("delivered expired attachment")
             end)
  end

  test "invalid ownership, target and delegation create no durable message", ctx do
    before = Repo.aggregate(OperatorMessage, :count)

    for {target, actor} <- [
          {ctx.routine.id, %{kind: :operator, id: uid("other-operator")}},
          {uid("wrong-target"), ctx.actor},
          {ctx.routine.id, %{kind: :routine, id: ctx.routine.id}}
        ] do
      assert {:error, _} =
               OperatorMessages.submit(
                 target,
                 "inspect",
                 Keyword.put(opts(ctx), :actor, actor),
                 fn _ -> flunk("unauthorized delivery") end
               )
    end

    assert Repo.aggregate(OperatorMessage, :count) == before
  end

  test "attachment admission refuses an outer transaction before provider effects", ctx do
    assert {:ok, {:error, :outer_transaction_unsupported}} =
             Repo.transaction(fn ->
               OperatorMessages.submit(ctx.routine.id, "inspect", opts(ctx), fn _ ->
                 flunk("delivery before caller commit")
               end)
             end)
  end

  test "concurrent cleanup either expires before admission or preserves accepted bytes", ctx do
    for iteration <- 1..8 do
      {:ok, image} =
        Attachments.upload(ctx.actor, ctx.routine.id, "image/png", @png <> to_string(iteration))

      row = Repo.get_by!(Attachment, attachment_id: image.attachment_id)
      old = DateTime.add(DateTime.utc_now(), -90, :day)
      Repo.update!(Ecto.Changeset.change(row, inserted_at: old, updated_at: old))

      request_opts =
        opts(ctx, "prune-race-#{iteration}") |> Keyword.put(:attachment_id, image.attachment_id)

      submit =
        Task.async(fn ->
          receive do
            :go ->
              OperatorMessages.submit(ctx.routine.id, "inspect", request_opts, fn _ ->
                {:ok, :queued}
              end)
          end
        end)

      cleanup = Task.async(fn -> receive do: (:go -> Attachments.prune(30)) end)
      send(submit.pid, :go)
      send(cleanup.pid, :go)
      result = Task.await(submit)
      Task.await(cleanup)

      case result do
        {:ok, message, :created} ->
          assert message.attachment_id == image.attachment_id
          assert File.read!(row.path) == @png <> to_string(iteration)
          assert Repo.get!(Attachment, row.id).deleted_at == nil

        {:error, :attachment_expired} ->
          refute File.exists?(row.path)

          refute Repo.exists?(
                   from(m in OperatorMessage, where: m.attachment_id == ^image.attachment_id)
                 )
      end
    end
  end

  test "an invalid image reference cannot start an offline routine", ctx do
    assert {:error, _} =
             Actions.message_with_receipt(
               ctx.routine.id,
               "inspect",
               Keyword.put(opts(ctx), :attachment_id, Ecto.UUID.generate())
             )

    assert {:ok, :offline} = Agents.status(ctx.routine.id)
  end

  for provider <- [:claude, :codex], text <- ["", "look at this image"] do
    @provider provider
    @text text
    test "#{provider} accepts #{inspect(text)} plus image offline, paused and busy", ctx do
      provider = @provider
      routine = ctx.routine |> Map.put(:provider, provider) |> Map.delete(:model)
      put_env!(:routines, [routine])
      on_exit(fn -> Agents.stop_agent(routine.id, provider) end)

      assert {:ok, offline, :created} =
               Actions.message_with_receipt(routine.id, @text, opts(ctx, "offline"))

      assert offline.delivery == "started"

      job =
        eventually(fn ->
          jobs =
            Repo.all(
              from(j in Oban.Job,
                where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^routine.id
              )
            )

          assert job = Enum.find(jobs, &(&1.meta["correlation_id"] == offline.message_id))
          job
        end)

      assert job.args["prompt"] == offline.prompt
      assert offline.prompt =~ "attached image: "
      assert File.read!(image_path(offline.prompt)) == @png
      finish(provider, job)
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)
      assert :ok = Agents.stop_agent(routine.id, provider)

      parent = self()

      config =
        routine.id
        |> Routine.get()
        |> Routine.agent_config(%{})
        |> Keyword.put(:enqueue_fun, fn args, meta ->
          send(parent, {:enqueued_attachment, args, meta})
          {:ok, :queued}
        end)

      assert {:ok, _} = Agents.start_agent(routine.id, config)
      assert :ok = Agents.emergency_pause(routine.id, provider)
      assert {:ok, :paused} = Agents.await(routine.id, provider, :paused, 1_000)

      assert {:ok, paused, :created} =
               Actions.message_with_receipt(routine.id, @text, opts(ctx, "paused"))

      assert paused.delivery == "resumed"
      assert_receive {:enqueued_attachment, paused_args, paused_meta}, 1_000
      assert paused_args["prompt"] == paused.prompt
      assert paused_meta["correlation_id"] == paused.message_id

      assert {:ok, queued, :created} =
               Actions.message_with_receipt(routine.id, @text, opts(ctx, "busy"))

      assert queued.delivery == "queued"
      assert queued.attachment_id == ctx.attachment.attachment_id
      refute_receive {:enqueued_attachment, _, _}, 100
      finish(provider, %{meta: paused_meta})
      assert_receive {:enqueued_attachment, queued_args, queued_meta}, 1_000
      assert queued_args["prompt"] == queued.prompt
      assert queued_meta["correlation_id"] == queued.message_id
      finish(provider, %{meta: queued_meta})
    end
  end

  defp image_path(prompt) do
    [_, path] = Regex.run(~r/attached image: (.+) -- Read it before answering/, prompt)
    path
  end

  defp finish(:claude, job) do
    result = ObanClaude.Testing.result(result: "done", session_id: Ecto.UUID.generate())

    ObanClaude.Agent.Job.handle_result(
      result,
      struct(Oban.Job, Map.merge(%{attempt: 1, max_attempts: 1}, Map.take(job, [:id, :meta])))
    )
  end

  defp finish(:codex, job) do
    result = ObanCodex.Testing.result("done", session_id: Ecto.UUID.generate())

    ObanCodex.Agent.Job.handle_result(
      result,
      struct(Oban.Job, Map.merge(%{attempt: 1, max_attempts: 1}, Map.take(job, [:id, :meta])))
    )
  end
end
