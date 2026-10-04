defmodule Custode.PeerMessagesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, PeerMessage, PeerMessages, Repo, Routine}

  setup do
    routines =
      for provider <- [:claude, :codex, :claude] do
        %{
          id: uid("peer-#{provider}"),
          provider: provider,
          cron: :manual,
          workspace: tmp_workspace!(),
          prompt: "inspect requests under normal policy",
          on_note: :ignore
        }
      end

    put_env!(:routines, routines)
    put_env!(:peer_message_limits, [])
    [a, b, c] = Enum.map(routines, &%{kind: :routine, id: &1.id})
    %{a: a, b: b, c: c, routines: routines}
  end

  test "accepts a cross-provider envelope, job and feed event together", ctx do
    attrs = attrs(ctx.b.id, %{body: "  source text\n```elixir\n:ok\n```\n"})
    string_attrs = Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)

    assert {:ok, message} = PeerMessages.send(ctx.a, string_attrs)
    assert {:ok, _id} = Ecto.UUID.cast(message.id)
    assert message.sender == ctx.a.id
    assert message.recipient == ctx.b.id
    assert message.body == attrs.body
    assert message.correlation_id == message.id
    assert message.reply_to == nil
    assert message.depth == 0
    assert message.delivery_state == "pending"
    assert message.delivered_at == nil
    assert message.acknowledged_at == nil
    assert [%{args: %{"message_id" => id}}] = jobs(message.id)
    assert id == message.id
    assert [%{"event" => "peer_message_sent", "sender" => sender} = event] = events(message.id)
    assert sender == ctx.a.id
    refute Map.has_key?(event, "body")

    view = PeerMessages.view(message)
    assert is_binary(view.inserted_at)
    assert view.body == attrs.body
    refute Map.has_key?(view, :idempotency_key)
    assert {:ok, _json} = Jason.encode(view)
    assert Routine.get(ctx.a.id).provider == :claude
    assert Routine.get(ctx.b.id).provider == :codex
  end

  test "concurrent exact retries share one envelope, job and event", ctx do
    attrs = attrs(ctx.b.id)

    results =
      1..6
      |> Task.async_stream(fn _ -> PeerMessages.send(ctx.a, attrs) end,
        max_concurrency: 6,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, message}} -> message end)

    assert [id] = results |> Enum.map(& &1.id) |> Enum.uniq()
    assert length(jobs(id)) == 1
    assert length(events(id)) == 1
  end

  test "duplicate comparison covers every caller-controlled envelope field", ctx do
    attrs = attrs(ctx.b.id)
    assert {:ok, original} = PeerMessages.send(ctx.a, attrs)

    for change <- [
          %{recipient: ctx.c.id},
          %{kind: "fyi"},
          %{subject: "different subject"},
          %{body: "different body"}
        ] do
      assert {:error, :idempotency_conflict} =
               PeerMessages.send(ctx.a, Map.merge(attrs, change))
    end

    assert {:ok, incoming} = PeerMessages.send(ctx.b, attrs(ctx.a.id))

    assert {:error, :idempotency_conflict} =
             PeerMessages.reply(
               ctx.a,
               incoming.id,
               Map.take(attrs, [:subject, :body, :idempotency_key])
             )

    assert Repo.get!(PeerMessage, original.id).body == attrs.body
  end

  test "exact retries precede recipient revalidation and configured limits", ctx do
    attrs = attrs(ctx.b.id)
    assert {:ok, message} = PeerMessages.send(ctx.a, attrs)
    put_env!(:routines, Enum.reject(ctx.routines, &(&1.id == ctx.b.id)))
    put_env!(:peer_message_limits, sender_per_hour: 0)

    assert {:ok, same} = PeerMessages.send(ctx.a, attrs)
    assert same.id == message.id
    assert length(jobs(message.id)) == 1

    assert {:error, :idempotency_conflict} =
             PeerMessages.send(ctx.a, %{attrs | body: "changed"})
  end

  test "identity and address validation reject spoofing and authority changes", ctx do
    attrs = attrs(ctx.b.id)

    for identity <- [%{kind: :operator}, %{kind: :sub_agent, id: ctx.a.id}, %{}, nil] do
      assert {:error, :unauthorized} = PeerMessages.send(identity, attrs)
    end

    assert {:error, :unknown_routine} =
             PeerMessages.send(%{kind: :routine, id: uid("missing")}, attrs)

    assert {:error, {:invalid_fields, [:sender]}} =
             PeerMessages.send(ctx.a, Map.put(attrs, :sender, ctx.c.id))

    assert {:error, {:invalid_fields, ["correlation_id"]}} =
             PeerMessages.send(ctx.a, Map.put(attrs, "correlation_id", Ecto.UUID.generate()))

    assert {:error, {:invalid_field, :kind}} = PeerMessages.send(ctx.a, %{attrs | kind: "reply"})
    assert {:error, :self_message} = PeerMessages.send(ctx.a, %{attrs | recipient: ctx.a.id})

    assert {:error, :unknown_recipient} =
             PeerMessages.send(ctx.a, %{attrs | recipient: uid("gone")})

    assert {:ok, []} = PeerMessages.list(ctx.a)
  end

  test "limits count subject and key characters but enforce body bytes", ctx do
    boundary = %{
      subject: String.duplicate("é", 200),
      body: String.duplicate("é", 16_384),
      idempotency_key: String.duplicate("é", 128)
    }

    assert {:ok, _message} = PeerMessages.send(ctx.a, attrs(ctx.b.id, boundary))

    for {field, value} <- [
          subject: String.duplicate("é", 201),
          body: String.duplicate("é", 16_385),
          idempotency_key: String.duplicate("é", 129),
          body: " \n ",
          subject: nil
        ] do
      assert {:error, {:invalid_field, ^field}} =
               PeerMessages.send(ctx.a, Map.put(attrs(ctx.b.id), field, value))
    end

    for config <- [[sender_per_hour: 0], [max_depth: -1], [body_bytes: "100"], [unknown: 1]] do
      assert {:error, {:invalid_limit, _name}} =
               PeerMessages.send(ctx.a, attrs(ctx.b.id), limits: config)
    end
  end

  test "concurrent new messages cannot pass the same sender quota", ctx do
    results =
      1..4
      |> Task.async_stream(
        fn _ -> PeerMessages.send(ctx.a, attrs(ctx.b.id), limits: [sender_per_hour: 1]) end,
        max_concurrency: 4,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _message}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 3
  end

  test "the hourly quota expires and exact retries consume no additional allowance", ctx do
    now = ~U[2026-10-03 12:00:00Z]
    attrs = attrs(ctx.b.id)
    opts = [now: now, limits: [sender_per_hour: 1]]
    assert {:ok, first} = PeerMessages.send(ctx.a, attrs, opts)
    assert {:ok, same} = PeerMessages.send(ctx.a, attrs, opts)
    assert same.id == first.id
    assert {:error, :rate_limited} = PeerMessages.send(ctx.a, attrs(ctx.b.id), opts)

    assert {:ok, _second} =
             PeerMessages.send(
               ctx.a,
               attrs(ctx.b.id),
               Keyword.put(opts, :now, DateTime.add(now, 3600))
             )
  end

  test "replies derive both addresses and root identity and obey depth and root limits", ctx do
    assert {:ok, root} = PeerMessages.send(ctx.a, attrs(ctx.b.id))
    reply_attrs = reply_attrs()
    assert {:ok, reply} = PeerMessages.reply(ctx.b, root.id, reply_attrs)
    assert reply.sender == ctx.b.id
    assert reply.recipient == ctx.a.id
    assert reply.kind == "reply"
    assert reply.reply_to == root.id
    assert reply.correlation_id == root.id
    assert reply.depth == 1
    assert {:ok, same} = PeerMessages.reply(ctx.b, root.id, reply_attrs, limits: [max_depth: 1])
    assert same.id == reply.id

    assert {:error, :unauthorized} = PeerMessages.reply(ctx.a, root.id, reply_attrs())
    assert {:error, :unauthorized} = PeerMessages.reply(ctx.c, root.id, reply_attrs())

    assert {:error, :depth_limit} =
             PeerMessages.reply(ctx.a, reply.id, reply_attrs(), limits: [max_depth: 1])

    assert {:ok, branch} =
             PeerMessages.reply(ctx.b, root.id, reply_attrs(),
               limits: [max_correlation_messages: 3]
             )

    assert branch.correlation_id == root.id

    assert {:error, :correlation_limit} =
             PeerMessages.reply(ctx.a, reply.id, reply_attrs(),
               limits: [max_correlation_messages: 3]
             )
  end

  test "an enqueue failure rolls back the envelope, job and feed event", ctx do
    enqueue = fn changeset ->
      assert {:ok, _job} = Oban.insert(changeset)
      {:error, :test_failure}
    end

    before_jobs = length(jobs_for("Custode.PeerMessageJob"))

    assert {:error, {:enqueue_failed, :test_failure}} =
             PeerMessages.send(ctx.a, attrs(ctx.b.id), enqueue: enqueue)

    assert {:ok, []} = PeerMessages.list(ctx.a)
    assert Feed.for_agent(ctx.a.id) == []
    assert length(jobs_for("Custode.PeerMessageJob")) == before_jobs
  end

  test "reads are participant scoped, stable, paginated and never acknowledge", ctx do
    now = ~U[2026-10-03 12:00:00Z]
    assert {:ok, first} = PeerMessages.send(ctx.a, attrs(ctx.b.id), now: now)
    assert {:ok, second} = PeerMessages.send(ctx.b, attrs(ctx.a.id), now: now)
    assert {:ok, third} = PeerMessages.send(ctx.a, attrs(ctx.c.id), now: now)
    assert {:ok, foreign} = PeerMessages.send(ctx.b, attrs(ctx.c.id), now: now)
    ids = Enum.sort([first.id, second.id, third.id], :desc)

    assert {:ok, rows} = PeerMessages.list(ctx.a)
    assert Enum.map(rows, & &1.id) == ids
    assert {:ok, [middle]} = PeerMessages.list(ctx.a, limit: 1, offset: 1)
    assert middle.id == Enum.at(ids, 1)
    assert {:ok, [received]} = PeerMessages.list(ctx.a, direction: :inbox)
    assert received.id == second.id
    assert {:ok, pair} = PeerMessages.list(ctx.a, counterpart: ctx.b.id)
    assert Enum.sort(Enum.map(pair, & &1.id)) == Enum.sort([first.id, second.id])
    assert {:ok, [root]} = PeerMessages.list(ctx.a, correlation_id: first.id)
    assert root.id == first.id
    assert {:ok, operator_rows} = PeerMessages.list(%{kind: :operator}, participant: ctx.a.id)
    assert Enum.map(operator_rows, & &1.id) == ids
    assert {:ok, _foreign} = PeerMessages.read(%{kind: :operator}, foreign.id)
    assert {:error, :not_found} = PeerMessages.read(ctx.a, foreign.id)
    assert {:error, :unauthorized} = PeerMessages.list(ctx.a, participant: ctx.b.id)
    assert {:error, :unauthorized} = PeerMessages.list(%{kind: :sub_agent, id: ctx.a.id})
    assert {:ok, unchanged} = PeerMessages.read(ctx.b, first.id)
    assert unchanged == first
    assert Repo.get!(PeerMessage, first.id).acknowledged_at == nil
  end

  test "list rejects unbounded or invalid filters", ctx do
    assert {:error, {:invalid_field, :participant}} =
             PeerMessages.list(%{kind: :operator}, direction: :inbox)

    for opts <- [
          [limit: 0],
          [limit: 101],
          [offset: -1],
          [offset: 10_001],
          [direction: :other],
          [correlation_id: "not-a-uuid"],
          [counterpart: 12]
        ] do
      assert {:error, {:invalid_field, _field}} = PeerMessages.list(ctx.a, opts)
    end
  end

  test "only the recipient explicitly acknowledges, once, without claiming work completion",
       ctx do
    assert {:ok, message} = PeerMessages.send(ctx.a, attrs(ctx.b.id))
    assert {:error, :unauthorized} = PeerMessages.acknowledge(ctx.a, message.id)
    assert {:error, :unauthorized} = PeerMessages.acknowledge(ctx.c, message.id)
    assert {:error, :unauthorized} = PeerMessages.acknowledge(%{kind: :operator}, message.id)
    assert {:ok, acknowledged} = PeerMessages.acknowledge(ctx.b, message.id)
    assert %DateTime{} = acknowledged.acknowledged_at
    assert acknowledged.delivery_state == "pending"
    assert acknowledged.delivered_at == nil

    assert {:ok, same} =
             PeerMessages.acknowledge(ctx.b, message.id,
               enqueue: fn _ -> flunk("duplicate enqueue") end
             )

    assert same.acknowledged_at == acknowledged.acknowledged_at
    assert Enum.count(events(message.id), &(&1["event"] == "peer_message_acknowledged")) == 1
  end

  test "acknowledgment rollback and notebook filing both use the canonical envelope", ctx do
    assert {:ok, message} = PeerMessages.send(ctx.a, attrs(ctx.b.id))

    assert {:error, {:enqueue_failed, :offline}} =
             PeerMessages.acknowledge(ctx.b, message.id, enqueue: fn _ -> {:error, :offline} end)

    assert Repo.get!(PeerMessage, message.id).acknowledged_at == nil
    refute Enum.any?(events(message.id), &(&1["event"] == "peer_message_acknowledged"))
    assert :ok = PeerMessages.acknowledge_note(ctx.a.id, "peer-#{message.id}.md")
    assert Repo.get!(PeerMessage, message.id).acknowledged_at == nil
    assert :ok = PeerMessages.acknowledge_note(ctx.b.id, "../peer-#{message.id}.md")
    assert :ok = PeerMessages.acknowledge_note(ctx.b.id, "normal-note.md")
    assert :ok = PeerMessages.acknowledge_note(ctx.b.id, "peer-#{message.id}.md")
    assert %DateTime{} = Repo.get!(PeerMessage, message.id).acknowledged_at
  end

  test "legacy peer note authorization fails closed and never lets operators acknowledge", ctx do
    assert {:ok, message} = PeerMessages.send(ctx.a, attrs(ctx.b.id))
    name = "peer-#{message.id}.md"
    assert {:ok, id} = PeerMessages.note_id(name)
    assert id == message.id
    assert :error = PeerMessages.note_id("../#{name}")
    assert :ok = PeerMessages.authorize_note(ctx.a, ctx.b.id, name, :read)
    assert :ok = PeerMessages.authorize_note(ctx.b, ctx.b.id, name, :read)
    assert :ok = PeerMessages.authorize_note(%{kind: :operator}, ctx.b.id, name, :read)
    assert {:error, :unauthorized} = PeerMessages.authorize_note(ctx.c, ctx.b.id, name, :read)
    assert {:error, :unauthorized} = PeerMessages.authorize_note(ctx.a, ctx.b.id, name, :file)

    assert {:error, :unauthorized} =
             PeerMessages.authorize_note(%{kind: :operator}, ctx.b.id, name, :file)

    assert {:error, :unauthorized} = PeerMessages.authorize_note(ctx.b, ctx.c.id, name, :file)
    assert :ok = PeerMessages.authorize_note(ctx.b, ctx.b.id, name, :file)
    assert Repo.get!(PeerMessage, message.id).acknowledged_at == nil

    orphan = "peer-#{Ecto.UUID.generate()}.md"
    assert {:error, :unauthorized} = PeerMessages.authorize_note(ctx.b, ctx.b.id, orphan, :read)
    assert {:error, :unauthorized} = PeerMessages.authorize_note(ctx.b, ctx.b.id, orphan, :file)
    assert :ok = PeerMessages.authorize_note(nil, ctx.b.id, "normal-note.md", :read)

    assert :ok =
             PeerMessages.authorize_note(%{kind: :operator}, ctx.b.id, "normal-note.md", :file)
  end

  defp attrs(recipient, overrides \\ %{}) do
    Map.merge(
      %{
        recipient: recipient,
        kind: "request",
        subject: "Review this change",
        body: "Check the linked evidence under your normal policy.",
        idempotency_key: uid("peer-key")
      },
      overrides
    )
  end

  defp reply_attrs,
    do: %{subject: "Review result", body: "Evidence is ready.", idempotency_key: uid("reply-key")}

  defp jobs(id) do
    "Custode.PeerMessageJob"
    |> jobs_for()
    |> Enum.filter(&(&1.args["message_id"] == id))
  end

  defp events(id) do
    Repo.all(from(entry in Feed.Entry, order_by: [asc: entry.id], select: entry.entry))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["peer_message_id"] == id))
  end
end
