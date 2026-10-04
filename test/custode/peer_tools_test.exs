defmodule Custode.PeerToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Anubis.Server.{Frame, Handlers}
  alias Custode.MCP.{NotebookTools, PeerTools}
  alias Custode.{PeerMessage, PeerMessageDelivery, Repo, Routine}

  @operator %Frame{assigns: %{custode_identity: %{kind: :operator, id: "operator"}}}
  @tools [PeerTools.Send, PeerTools.Reply, PeerTools.List, PeerTools.Read, PeerTools.Ack]

  setup do
    routines =
      for label <- ~w(sender recipient outsider) do
        %{
          id: uid("peer-#{label}"),
          role: :backlog_worker,
          cron: :manual,
          on_note: :ignore,
          workspace: tmp_workspace!(),
          prompt: "test routine"
        }
      end

    put_env!(:routines, routines)
    ids = Enum.map(routines, & &1.id)
    on_exit(fn -> Repo.delete_all(from(m in PeerMessage, where: m.sender in ^ids)) end)
    [sender, recipient, outsider] = routines
    %{sender: sender.id, recipient: recipient.id, outsider: outsider.id}
  end

  test "schemas expose no writable identity and missing content reaches a tool error", ctx do
    for tool <- @tools do
      properties = tool.input_schema()["properties"]
      refute Map.has_key?(properties, "sender")
      refute Map.has_key?(properties, "agent_id")
    end

    for {name, params, field} <- [
          {"peer_send", %{}, "recipient"},
          {"peer_reply", %{}, "message_id"},
          {"peer_read", %{}, "message_id"},
          {"peer_ack", %{}, "message_id"}
        ] do
      assert wire_error(name, params, frame(ctx.sender)) =~ field
    end
  end

  test "all handlers require verified context and temporary agents have no peer access", ctx do
    for tool <- @tools do
      assert tool.execute(%{}, %Frame{}) |> tool_error() =~ "authenticated"

      params =
        if tool == PeerTools.Send,
          do: send_args(ctx.recipient),
          else: %{message_id: Ecto.UUID.generate()}

      params = if tool == PeerTools.List, do: %{}, else: params

      assert tool.execute(params, frame(ctx.sender, :sub_agent)) |> tool_error() =~
               "access denied"
    end
  end

  test "the authenticated sender survives a wire-level spoof and retries return the same row",
       ctx do
    args = send_args(ctx.recipient)
    wire_args = Map.new(args, fn {key, value} -> {Atom.to_string(key), value} end)

    %{"message" => message} =
      wire_json("peer_send", Map.put(wire_args, "sender", ctx.outsider), frame(ctx.sender))

    assert message["sender"] == ctx.sender
    assert message["recipient"] == ctx.recipient
    assert message["kind"] == "request"
    assert message["correlation_id"] == message["id"]
    assert message["body"] == args.body
    refute Map.has_key?(message, "idempotency_key")
    refute Map.has_key?(message, "completed")

    assert %{"message" => %{"id" => id}} =
             PeerTools.Send.execute(args, frame(ctx.sender)) |> tool_json()

    assert id == message["id"]
    assert Repo.aggregate(from(m in PeerMessage, where: m.sender == ^ctx.sender), :count) == 1

    assert PeerTools.Send.execute(Map.put(args, :body, "changed"), frame(ctx.sender))
           |> tool_error() =~ "idempotency_key"

    assert PeerTools.Send.execute(
             Map.put(send_args(ctx.recipient), :sender, ctx.outsider),
             frame(ctx.sender)
           )
           |> tool_error() =~ "unsupported"
  end

  test "reads are inert and restricted to the participants or operator", ctx do
    message = send_message(ctx)
    args = %{message_id: message["id"]}
    before = Repo.get!(PeerMessage, message["id"])

    for reader <- [frame(ctx.sender), frame(ctx.recipient), @operator] do
      assert %{"message" => %{"id" => id}} = PeerTools.Read.execute(args, reader) |> tool_json()
      assert id == message["id"]
    end

    assert Repo.get!(PeerMessage, message["id"]) == before
    assert PeerTools.Read.execute(args, frame(ctx.outsider)) |> tool_error() =~ "not found"
    assert %{"messages" => []} = PeerTools.List.execute(%{}, frame(ctx.outsider)) |> tool_json()

    assert %{"messages" => [%{"id" => id}]} =
             PeerTools.List.execute(
               %{direction: "received", counterpart: ctx.sender},
               frame(ctx.recipient)
             )
             |> tool_json()

    assert id == message["id"]

    assert %{"messages" => [%{"id" => ^id}]} =
             PeerTools.List.execute(%{participant: ctx.sender, correlation_id: id}, @operator)
             |> tool_json()

    assert PeerTools.List.execute(%{participant: ctx.sender}, frame(ctx.outsider))
           |> tool_error() =~ "access denied"
  end

  test "reply correlation and acknowledgment cannot become operator impersonation", ctx do
    message = send_message(ctx)
    id = message["id"]

    reply_args = %{
      message_id: id,
      subject: "Re: dependency",
      body: "I can investigate.",
      idempotency_key: uid("reply")
    }

    for writer <- [@operator, frame(ctx.outsider), frame(ctx.sender)] do
      assert PeerTools.Ack.execute(%{message_id: id}, writer) |> tool_error() != ""
      assert PeerTools.Reply.execute(reply_args, writer) |> tool_error() != ""
    end

    assert PeerTools.Send.execute(send_args(ctx.recipient), @operator) |> tool_error() =~
             "access denied"

    %{"message" => acknowledged} =
      PeerTools.Ack.execute(%{message_id: id}, frame(ctx.recipient)) |> tool_json()

    assert acknowledged["acknowledged_at"]
    refute Map.has_key?(acknowledged, "completed_at")

    assert %{"message" => ^acknowledged} =
             PeerTools.Ack.execute(%{message_id: id}, frame(ctx.recipient)) |> tool_json()

    %{"message" => reply} =
      PeerTools.Reply.execute(reply_args, frame(ctx.recipient)) |> tool_json()

    assert reply["sender"] == ctx.recipient
    assert reply["recipient"] == ctx.sender
    assert reply["kind"] == "reply"
    assert reply["reply_to"] == id
    assert reply["correlation_id"] == message["correlation_id"]
    assert reply["depth"] == 1

    assert %{"message" => %{"id" => reply_id}} =
             PeerTools.Reply.execute(reply_args, frame(ctx.recipient)) |> tool_json()

    assert reply_id == reply["id"]
  end

  test "invalid recipients, message ids and pagination return readable refusals", ctx do
    assert PeerTools.Send.execute(send_args(uid("missing")), frame(ctx.sender)) |> tool_error() =~
             "configured routine"

    assert PeerTools.Send.execute(send_args(ctx.sender), frame(ctx.sender)) |> tool_error() =~
             "another routine"

    assert PeerTools.Read.execute(%{message_id: "not-a-uuid"}, frame(ctx.sender)) |> tool_error() !=
             ""

    for params <- [
          %{limit: 101},
          %{limit: 0},
          %{offset: -1},
          %{offset: 10_001},
          %{direction: "elsewhere"}
        ] do
      assert PeerTools.List.execute(params, frame(ctx.sender)) |> tool_error() != ""
    end
  end

  test "the legacy inbox reader filters peer bodies while ordinary notes remain transparent",
       ctx do
    message = send_message(ctx)
    assert :ok = PeerMessageDelivery.deliver(message["id"])
    routine = Routine.get(ctx.recipient)
    inbox = Path.join(routine.workspace, "inbox")
    File.write!(Path.join(inbox, "ordinary.md"), "shared ordinary context")
    orphan = "peer-#{Ecto.UUID.generate()}.md"
    File.write!(Path.join(inbox, orphan), "orphaned peer body")
    params = %{routine_id: ctx.recipient}

    for reader <- [frame(ctx.outsider), frame(ctx.outsider, :sub_agent), %Frame{}] do
      assert %{"notes" => [%{"name" => "ordinary.md", "content" => "shared ordinary context"}]} =
               NotebookTools.InboxList.execute(params, reader) |> tool_json()
    end

    for reader <- [frame(ctx.sender), frame(ctx.recipient), @operator] do
      %{"notes" => notes} = NotebookTools.InboxList.execute(params, reader) |> tool_json()
      assert length(notes) == 2
      assert Enum.any?(notes, &String.contains?(&1["content"], message["body"] |> String.trim()))
      refute Enum.any?(notes, &(&1["name"] == orphan))
    end

    assert is_nil(Repo.get!(PeerMessage, message["id"]).acknowledged_at)
  end

  test "legacy peer filing refuses operator impersonation before changing the file", ctx do
    message = send_message(ctx)
    assert :ok = PeerMessageDelivery.deliver(message["id"])
    routine = Routine.get(ctx.recipient)
    name = "peer-#{message["id"]}.md"
    path = Path.join([routine.workspace, "inbox", name])
    content = File.read!(path)
    params = %{routine_id: ctx.recipient, name: name}

    for writer <- [@operator, %Frame{}, frame(ctx.sender), frame(ctx.outsider)] do
      assert NotebookTools.InboxMarkFiled.execute(params, writer) |> tool_error() != ""
      assert File.read!(path) == content
      assert is_nil(Repo.get!(PeerMessage, message["id"]).acknowledged_at)
    end

    assert %{"filed" => ^name} =
             NotebookTools.InboxMarkFiled.execute(params, frame(ctx.recipient)) |> tool_json()

    assert String.starts_with?(File.read!(path), "FILED ")
    assert Repo.get!(PeerMessage, message["id"]).acknowledged_at

    File.write!(Path.join([routine.workspace, "inbox", "ordinary.md"]), "ordinary note")

    assert %{"filed" => "ordinary.md"} =
             NotebookTools.InboxMarkFiled.execute(%{params | name: "ordinary.md"}, @operator)
             |> tool_json()
  end

  defp send_args(recipient) do
    %{
      recipient: recipient,
      kind: "request",
      subject: "Dependency",
      body: "  Please inspect the upstream change.\n",
      idempotency_key: uid("send")
    }
  end

  defp send_message(ctx) do
    %{"message" => message} =
      PeerTools.Send.execute(send_args(ctx.recipient), frame(ctx.sender)) |> tool_json()

    message
  end

  defp frame(id, kind \\ :routine),
    do: %Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}

  defp wire(name, arguments, frame) do
    Handlers.Tools.handle_call(
      %{"params" => %{"name" => name, "arguments" => arguments}},
      frame,
      Custode.MCP.Server
    )
  end

  defp wire_json(name, arguments, frame) do
    {:reply, %{"isError" => false, "content" => [%{"text" => text} | _]}, _} =
      wire(name, arguments, frame)

    Jason.decode!(text)
  end

  defp wire_error(name, arguments, frame) do
    {:reply, %{"isError" => true, "content" => [%{"text" => text} | _]}, _} =
      wire(name, arguments, frame)

    text
  end
end
