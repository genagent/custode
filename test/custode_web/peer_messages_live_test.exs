defmodule CustodeWeb.PeerMessagesLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.{PeerMessages, Repo}

  @endpoint CustodeWeb.Endpoint

  setup do
    put_env!(:feed_path, nil)
    sender = uid("peer-ui-claude")
    recipient = uid("peer-ui-codex")

    put_env!(:routines, [
      %{
        id: sender,
        provider: :claude,
        cron: "@daily",
        workspace: tmp_workspace!(),
        prompt: "sweep"
      },
      %{
        id: recipient,
        provider: :codex,
        cron: "@daily",
        workspace: tmp_workspace!(),
        prompt: "sweep"
      }
    ])

    attrs = %{
      recipient: recipient,
      kind: "request",
      subject: "Review the compatibility evidence",
      body: "Evidence: <script>alert('no')</script>",
      idempotency_key: uid("peer-ui-key")
    }

    {:ok, message} = PeerMessages.send(identity(sender), attrs)
    %{conn: build_conn(), sender: sender, recipient: recipient, message: message}
  end

  test "both agents and the fleet expose the same exchange without acknowledging", context do
    %{conn: conn, sender: sender, recipient: recipient, message: message} = context

    for participant <- [sender, recipient] do
      {:ok, view, _html} = live(conn, "/messages?" <> URI.encode_query(%{agent: participant}))
      assert has_element?(view, "#peer-message-#{message.id}", message.subject)
      assert has_element?(view, "#peer-message-#{message.id}", "Queued for delivery")
      assert has_element?(view, "a[href='/messages/#{message.id}']", "View exchange")
      refute render(view) =~ "<script>alert"
      {:ok, stored} = PeerMessages.read(identity(recipient), message.id)
      assert is_nil(stored.acknowledged_at)

      {:ok, console, _html} = live(conn, "/console/#{participant}")
      assert has_element?(console, "a[href='/messages?agent=#{participant}']", "Agent messages")
    end

    {:ok, feed, _html} = live(conn, "/feed?agent=#{sender}")
    assert has_element?(feed, "a[href='/messages']", "Agent messages")
    assert has_element?(feed, "a[href='/messages/#{message.id}']", "View agent exchange")
  end

  test "reopening an exchange reconstructs its replies from durable storage", context do
    %{conn: conn, sender: sender, recipient: recipient, message: message} = context

    {:ok, reply} =
      PeerMessages.reply(identity(recipient), message.id, %{
        subject: "Review findings",
        body: "The evidence is incomplete.",
        idempotency_key: uid("peer-ui-reply")
      })

    {:ok, _acked} = PeerMessages.acknowledge(identity(recipient), message.id)

    for _visit <- 1..2 do
      {:ok, view, html} = live(conn, "/messages/#{reply.id}")
      assert has_element?(view, "#peer-message-#{message.id}", "Acknowledged")
      assert has_element?(view, "#peer-message-#{reply.id}", reply.body)
      assert html =~ "not that"
      assert html =~ "the work is complete"

      assert [original_id, reply_id] =
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query("article[id^=peer-message-]")
               |> LazyHTML.attribute("id")

      assert original_id == "peer-message-#{message.id}"
      assert reply_id == "peer-message-#{reply.id}"
      {:ok, stored} = PeerMessages.read(identity(sender), reply.id)
      assert is_nil(stored.acknowledged_at)
    end
  end

  test "acknowledgment updates a connected view without hiding the message", context do
    %{conn: conn, recipient: recipient, message: message} = context
    {:ok, view, _html} = live(conn, "/messages/#{message.id}")
    refute has_element?(view, "#peer-message-#{message.id} .badge", "Acknowledged")
    {:ok, _message} = PeerMessages.acknowledge(identity(recipient), message.id)
    assert has_element?(view, "#peer-message-#{message.id} .badge", "Acknowledged")
  end

  test "an invalid exchange is a read-only not-found view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages/not-an-id")
    assert has_element?(view, "[role=alert]", "could not be found")
    refute has_element?(view, "article")
  end

  test "the message history survives pruning the activity feed", context do
    %{conn: conn, sender: sender, message: message} = context
    Repo.query!("DELETE FROM feed_entries WHERE agent = ?", [sender])
    {:ok, view, _html} = live(conn, "/messages?agent=#{sender}")
    assert has_element?(view, "#peer-message-#{message.id}", message.subject)
  end

  test "older exchange pages retain the root filter", %{conn: conn, message: message} do
    fields = [
      :sender,
      :recipient,
      :kind,
      :subject,
      :body,
      :correlation_id,
      :depth,
      :delivery_state
    ]

    rows =
      for index <- 1..100 do
        at = DateTime.add(message.inserted_at, index, :second)

        message
        |> Map.take(fields)
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          idempotency_key: uid("page"),
          inserted_at: at,
          updated_at: at
        })
      end

    Repo.insert_all(Custode.PeerMessage, rows)
    {:ok, view, _html} = live(conn, "/messages/#{message.id}")
    refute has_element?(view, "#peer-message-#{message.id}")
    view |> element("a", "Older messages") |> render_click()
    assert_patch(view, "/messages/#{message.id}?offset=100")
    assert has_element?(view, "#peer-message-#{message.id}")
    assert has_element?(view, "a", "Newer messages")
  end

  defp identity(id), do: %{kind: :routine, id: id}
end
