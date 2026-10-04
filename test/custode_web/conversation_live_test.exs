defmodule CustodeWeb.ConversationLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.{OperatorMessage, OperatorMessages, Repo, Routine}

  @endpoint CustodeWeb.Endpoint

  setup do
    Repo.delete_all(OperatorMessage)
    clear_attention!()

    path = Path.join(System.tmp_dir!(), uid("conversation-lv") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    agent_id = uid("conversation-agent")
    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{
        id: agent_id,
        provider: :claude,
        model: "sonnet",
        effort: :high,
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep"
      }
    ])

    on_exit(fn -> Repo.delete_all(OperatorMessage) end)

    %{agent: Routine.get(agent_id), conn: build_conn()}
  end

  test "the stable deep link is a focused agent conversation with its shared composer", %{
    agent: agent,
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")

    assert has_element?(view, "#application-header")
    assert has_element?(view, "header h1", agent.id)

    assert has_element?(
             view,
             ~s(header a[href="/console/#{agent.id}"]),
             "control room"
           )

    assert has_element?(view, "header p", "claude · sonnet · high effort")
    assert has_element?(view, "#conversation-scroll[role=log][phx-hook=ConversationScroll]")

    refute has_element?(view, "#subject-rail")
    refute has_element?(view, "#console-controls")
    refute has_element?(view, ~s([role="tablist"]))

    assert has_element?(view, "#conversation-empty", "Start the conversation")
    refute has_element?(view, "#conversation-history-boundary")

    assert has_element?(
             view,
             ~s(form#message-0[phx-hook="SubjectDraft"][data-subject-draft][data-subject="#{agent.id}"])
           )

    assert has_element?(view, "#message-0 label[for=message-input-0]", "Message #{agent.id}")

    assert has_element?(
             view,
             "#message-input-0[data-draft-input][aria-describedby=message-help-0]"
           )

    assert has_element?(view, "#message-help-0", "Sending starts a turn with your message.")
    assert has_element?(view, "#message-0 input[type=file]")
    assert has_element?(view, "#message-0 button[type=submit]", "Start and send")
  end

  test "one durable exchange renders its question, continued reply, and markdown result together",
       %{
         agent: agent,
         conn: conn
       } do
    first = operator_message!(agent.id, attachment_prompt())

    first =
      first
      |> Ecto.Changeset.change(
        status: "waiting_for_input",
        detail: "staging or production?",
        result: %{
          "output" => %{
            "directive" => "ask_user",
            "question" => "staging or production?"
          }
        }
      )
      |> Repo.update!()

    reply = operator_message!(agent.id, "staging")
    assert reply.provider_correlation_id == first.provider_correlation_id
    assert reply.continues_message_id == first.message_id

    completed_at = DateTime.utc_now()

    first
    |> Ecto.Changeset.change(status: "completed", completed_at: completed_at)
    |> Repo.update!()

    reply
    |> Ecto.Changeset.change(
      status: "completed",
      provider: "claude",
      result: %{"output" => "Target **recorded**.\n\n- queued for deploy"},
      completed_at: completed_at
    )
    |> Repo.update!()

    {:ok, _noise, :created} =
      OperatorMessages.submit(
        agent.id,
        "scheduled sweep noise",
        [actor: %{kind: :routine, id: "nightly-sweep"}, via: :internal],
        fn _message -> {:ok, :delivered} end
      )

    {:ok, view, html} = live(conn, "/agents/#{agent.id}/conversation")

    assert has_element?(
             view,
             ~s(article[data-conversation-exchange][data-status="completed"])
           )

    assert html =~ "inspect the screenshot"
    assert html =~ "screenshot.png"
    refute html =~ "attached image:"
    assert html =~ "staging or production?"
    assert html =~ "you replied"
    assert html =~ "staging"
    refute html =~ "scheduled sweep noise"

    assert has_element?(view, "article[data-conversation-exchange] strong", "recorded")
    assert has_element?(view, "article[data-conversation-exchange] li", "queued for deploy")
    assert has_element?(view, "article[data-conversation-exchange] .badge", "complete")
    assert has_element?(view, "#conversation-history-boundary")
    refute has_element?(view, "#conversation-empty")
  end

  test "the control room links the selected agent to its focused conversation", %{
    agent: agent,
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/console/#{agent.id}")

    assert has_element?(
             view,
             ~s(main a[href="/agents/#{agent.id}/conversation"]),
             "conversation"
           )
  end

  defp operator_message!(agent_id, prompt) do
    assert {:ok, message, :created} =
             OperatorMessages.submit(
               agent_id,
               prompt,
               [actor: %{kind: :operator, id: "dashboard-test"}, via: :liveview],
               fn _message -> {:ok, :delivered} end
             )

    message
  end

  defp attachment_prompt do
    """
    inspect the screenshot
    attached image: /missing/screenshot.png -- Read it before answering
    """
  end
end
