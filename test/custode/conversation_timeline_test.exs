defmodule Custode.ConversationTimelineTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{ConversationTimeline, Feed, OperatorMessages, Repo}

  test "mixed history pages chronologically without gaps, sensor noise or foreign records" do
    agent = uid("timeline")
    other = uid("other-timeline")
    first = message!(agent, "first", ~U[2026-01-31 23:59:59.000000Z])
    update!(agent, "second", ~U[2026-02-01 00:00:00.000000Z])
    message!(agent, "third", ~U[2026-02-01 00:00:01.000000Z])
    update!(agent, "fourth", ~U[2026-02-01 00:00:02.000000Z])
    update!(other, "private other project", ~U[2026-02-01 00:00:03.000000Z])
    Feed.record(%{event: "sensor", agent: agent, summary: "sensor noise"})

    assert {:ok, page} = ConversationTimeline.page(agent, limit: 2)
    assert Enum.map(page.items, & &1.kind) == [:exchange, :update]
    assert page.has_older
    assert {:ok, older} = ConversationTimeline.page(agent, limit: 2, before: page.before)
    assert Enum.map(older.items, & &1.kind) == [:exchange, :update]
    assert hd(older.exchanges).id == first.provider_correlation_id
    refute older.has_older
    assert length(Enum.uniq_by(older.items ++ page.items, & &1.id)) == 4
    encoded = inspect(page) <> inspect(older)
    refute encoded =~ "sensor noise"
    refute encoded =~ "private other project"
    assert {:error, :invalid_cursor} = ConversationTimeline.page(other, before: page.before)
  end

  test "older pages freeze both row sources while new continuations and updates arrive" do
    agent = uid("timeline-watermark")
    old = message!(agent, "original", ~U[2026-10-01 00:00:00.000000Z])
    update!(agent, "middle", ~U[2026-10-01 00:01:00.000000Z])
    message!(agent, "latest", ~U[2026-10-01 00:02:00.000000Z])
    assert {:ok, initial} = ConversationTimeline.page(agent, limit: 1)
    old |> Ecto.Changeset.change(status: "waiting_for_input") |> Repo.update!()
    reply = message!(agent, "new continuation", ~U[2026-10-01 00:03:00.000000Z])
    assert reply.provider_correlation_id == old.provider_correlation_id
    update!(agent, "new update", ~U[2026-10-01 00:04:00.000000Z])

    assert {:ok, middle} = ConversationTimeline.page(agent, limit: 1, before: initial.before)
    assert [unit] = middle.items
    assert unit.update.entry["summary"] == "middle"
    assert {:ok, oldest} = ConversationTimeline.page(agent, limit: 1, before: middle.before)
    assert [exchange] = oldest.exchanges
    assert Enum.map(exchange.prompts, & &1.text) == ["original"]
    refute oldest.has_older
    assert {:ok, fresh} = ConversationTimeline.page(agent, limit: 10)
    assert Enum.any?(fresh.updates, &(&1.entry["summary"] == "new update"))
    assert Enum.any?(fresh.exchanges, &(length(&1.prompts) == 2))
  end

  test "only exact execution identity attaches a report; equal text is not correlation" do
    agent = uid("timeline-correlation")
    message = message!(agent, "request", ~U[2026-10-01 00:00:00.000000Z])

    message
    |> Ecto.Changeset.change(provider: "claude", agent_generation: "g", agent_turn_id: "t")
    |> Repo.update!()

    exact = %{
      "provider" => "claude",
      "generation" => "g",
      "turn_id" => "t",
      "correlation_id" => message.provider_correlation_id,
      "report" => %{"done" => ["Specific findings."]}
    }

    linked = update!(agent, "same words", ~U[2026-10-01 00:01:00.000000Z], exact)

    mismatch =
      update!(
        agent,
        "same words",
        ~U[2026-10-01 00:02:00.000000Z],
        Map.put(exact, "generation", "other")
      )

    assert {:ok, page} = ConversationTimeline.page(agent)
    assert [%{reports: [report]}] = page.exchanges
    assert report.id == linked.id
    assert [%{id: id}] = page.updates
    assert id == mismatch.id
    assert length(page.items) == 2

    # A report initially shown independently can become correlated after
    # the message's execution identity is persisted. Cached units stay unique.
    stale_update = %{id: linked.id, at: linked.at, entry: exact}
    assert length(ConversationTimeline.items(page.exchanges, [stale_update | page.updates])) == 2
  end

  test "loaded old exchanges refresh after many newer work updates" do
    agent = uid("timeline-late")
    message = message!(agent, "long work", ~U[2026-10-01 00:00:00.000000Z])
    assert {:ok, initial} = ConversationTimeline.page(agent)

    for n <- 1..25,
        do: update!(agent, "other interval", DateTime.add(message.inserted_at, n, :second))

    message
    |> Ecto.Changeset.change(status: "completed", result: %{"output" => "Exact late answer."})
    |> Repo.update!()

    assert [%{answer: "Exact late answer."}] =
             ConversationTimeline.refresh_exchanges(agent, initial.exchanges)
  end

  test "malformed and cross-source cursors return errors rather than raising" do
    agent = uid("bad-timeline")

    for cursor <- [42, "garbage", String.duplicate("a", 5000)] do
      assert {:error, :invalid_cursor} = ConversationTimeline.page(agent, before: cursor)
    end

    invalid =
      %{
        resource: "conversation_timeline.v1",
        scope: agent,
        at: 42,
        kind: 1,
        id: 1,
        messages: 1,
        feeds: 1
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_cursor} = ConversationTimeline.page(agent, before: invalid)
    assert {:error, :invalid_limit} = ConversationTimeline.page(agent, limit: 101)
  end

  defp message!(agent, text, at) do
    {:ok, message, :created} =
      OperatorMessages.submit(
        agent,
        text,
        [actor: %{kind: :operator, id: "timeline-operator"}],
        fn _ -> {:ok, :delivered} end
      )

    message |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  defp update!(agent, summary, at, extra \\ %{}) do
    entry =
      Map.merge(
        %{
          "event" => "turn",
          "agent" => agent,
          "summary" => summary,
          "at" => DateTime.to_iso8601(at)
        },
        extra
      )

    Repo.insert!(%Feed.Entry{agent: agent, event: "turn", at: at, entry: Jason.encode!(entry)})
  end
end
