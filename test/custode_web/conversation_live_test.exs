defmodule CustodeWeb.ConversationLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.{Feed, Gates, OperatorMessage, OperatorMessages, Repo, Routine}
  alias Custode.Feed.Ingest
  alias ObanClaude.{Agent, Testing}

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

  test "current input survives a new view and refreshes without starting the agent", %{
    agent: agent,
    conn: conn
  } do
    {:ok, first, _html} = live(conn, "/agents/#{agent.id}/conversation")
    assert has_element?(first, "#current-run-facts summary", "0 queued")

    {:ok, receipt, :created} =
      OperatorMessages.submit(
        agent.id,
        "retain this pending constraint",
        [actor: %{kind: :operator, id: "operator"}, idempotency_key: uid("queue-ui")],
        fn _message -> {:ok, :queued} end
      )

    send(first.pid, {:status_changed, agent.id})
    assert has_element?(first, "#current-run-facts summary", "1 queued")
    assert has_element?(first, "#current-run-facts", receipt.message_id)
    {:ok, reloaded, _html} = live(build_conn(), "/agents/#{agent.id}/conversation")
    assert has_element?(reloaded, "#current-run-facts summary", "1 queued")
    assert :offline = Custode.Agents.live_provider(agent.id)
    assert {:ok, _claimed} = OperatorMessages.claim_delivery(receipt)
    send(reloaded.pid, {:status_changed, agent.id})
    assert has_element?(reloaded, "#current-run-facts summary", "0 queued · 1 admitting")
    assert :offline = Custode.Agents.live_provider(agent.id)
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

  test "an explicit answer stays visible alongside a pending question", %{
    agent: agent,
    conn: conn
  } do
    message =
      gated_operator_message!(
        agent.id,
        %{
          "directive" => "ask_user",
          "summary" => "Waiting for the deployment target.",
          "answer" => "The **staging** checks passed. Production remains unchecked.",
          "question" => "Which deployment target should I inspect next?"
        },
        :waiting_for_user,
        "waiting_for_input"
      )

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    exchange = "#exchange-#{message.provider_correlation_id}"

    assert has_element?(view, exchange <> ~s([data-status="waiting_for_input"]))
    assert has_element?(view, exchange <> " strong", "staging")
    assert has_element?(view, exchange, "Production remains unchecked.")
    assert has_element?(view, exchange, "Which deployment target should I inspect next?")
    assert has_element?(view, exchange <> " #conversation-actions form#reply-answer-0")
    assert has_element?(view, "#message-0 button[type=submit]", "Answer")

    view |> element("#conversation-updates-toggle") |> render_click()
    assert has_element?(view, exchange <> " strong", "staging")
    assert has_element?(view, exchange <> " #conversation-actions form#reply-answer-0")
  end

  test "an explicit answer stays visible alongside pending approval controls", %{
    agent: agent,
    conn: conn
  } do
    message =
      gated_operator_message!(
        agent.id,
        %{
          "directive" => "request_permission",
          "summary" => "Deployment review needs approval.",
          "answer" => "The **review** found a rollback step missing from the plan.",
          "action" => "Add the rollback step to the deployment plan"
        },
        :awaiting_permission,
        "waiting_for_approval"
      )

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    exchange = "#exchange-#{message.provider_correlation_id}"

    assert has_element?(view, exchange <> ~s([data-status="waiting_for_approval"]))
    assert has_element?(view, exchange <> " strong", "review")
    assert has_element?(view, exchange, "Add the rollback step to the deployment plan")
    assert has_element?(view, exchange <> ~s( #conversation-actions button[phx-value-op=approve]))

    assert has_element?(
             view,
             exchange <> ~s( #conversation-actions form[phx-submit=reject] button[type=submit])
           )

    view |> element("#conversation-updates-toggle") |> render_click()
    assert has_element?(view, exchange <> " strong", "review")
    assert has_element?(view, exchange <> ~s( #conversation-actions button[phx-value-op=approve]))
  end

  test "a report-only turn with an explicit null answer does not turn its summary into chat", %{
    agent: agent,
    conn: conn
  } do
    summary = "Report-only status must stay out of the answer."
    report = %{"verified" => ["Checked the deployment status."]}
    generation = uid("report-generation")
    turn = uid("report-turn")

    message =
      operator_message!(agent.id, "Inspect the deployment status")
      |> Ecto.Changeset.change(
        status: "completed",
        provider: "claude",
        agent_generation: generation,
        agent_turn_id: turn,
        result: %{
          "output" => %{
            "directive" => "none",
            "summary" => summary,
            "answer" => nil,
            "report" => report
          }
        }
      )
      |> Repo.update!()

    Feed.record(%{
      event: "turn",
      agent: agent.id,
      provider: "claude",
      correlation_id: message.provider_correlation_id,
      generation: generation,
      turn_id: turn,
      summary: summary,
      report: report
    })

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    exchange = "#exchange-#{message.provider_correlation_id}"

    assert has_element?(view, exchange <> " details", "Checked the deployment status.")
    refute has_element?(view, exchange, summary)

    view |> element("#conversation-updates-toggle") |> render_click()
    refute has_element?(view, exchange <> " details")
    refute has_element?(view, exchange, summary)
    assert has_element?(view, exchange, "Inspect the deployment status")
  end

  test "a legacy structured question already shown as prompt detail is not repeated as an answer",
       %{
         agent: agent,
         conn: conn
       } do
    detail = "Which legacy deployment target should I inspect?"

    message =
      operator_message!(agent.id, "Inspect the legacy deployment")
      |> Ecto.Changeset.change(
        status: "completed",
        detail: detail,
        result: %{
          "output" => %{
            "directive" => "ask_user",
            "question" => detail,
            "summary" => "Waiting for the legacy deployment target."
          }
        }
      )
      |> Repo.update!()

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    exchange = "#exchange-#{message.provider_correlation_id}"
    html = view |> element(exchange) |> render()

    assert length(:binary.matches(html, detail)) == 1
    refute has_element?(view, exchange, "Waiting for the legacy deployment target.")
  end

  test "a failed continuation retains the full earlier answer beyond the feed response cap", %{
    agent: agent,
    conn: conn
  } do
    evidence = String.duplicate("Detailed retained evidence. ", 800)
    answer = "**Earlier assessment**\n\n" <> evidence <> "\n\nEND_OF_EARLIER_ANSWER"
    assert byte_size(answer) > 16_384

    original =
      operator_message!(agent.id, "Assess the deployment before choosing a target")
      |> Ecto.Changeset.change(
        status: "waiting_for_input",
        detail: "Which deployment target should I inspect?"
      )
      |> Repo.update!()

    continuation = operator_message!(agent.id, "Inspect staging")
    assert continuation.continues_message_id == original.message_id
    assert continuation.provider_correlation_id == original.provider_correlation_id

    prior = %{
      "id" => uid("prior-answer"),
      "message_id" => original.message_id,
      "answer" => answer,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    for message <- [original, continuation] do
      message
      |> Ecto.Changeset.change(
        status: "failed",
        result: %{"output" => nil, "prior_answers" => [prior]},
        error: %{"kind" => "provider_result_error", "detail" => "Continuation could not start."}
      )
      |> Repo.update!()
    end

    assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(agent.id)
    assert exchange.answer == nil
    assert exchange.prior_answers == [prior]

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    selector = "#exchange-#{original.provider_correlation_id}"

    assert has_element?(view, selector <> ~s([data-status="failed"]))
    assert has_element?(view, selector <> " [data-prior-answer]", "Earlier answer")
    assert has_element?(view, selector <> " [data-prior-answer] strong", "Earlier assessment")

    assert has_element?(
             view,
             selector <> " [data-prior-answer] [data-foldable-full]",
             "END_OF_EARLIER_ANSWER"
           )

    assert view |> element(selector <> " [data-prior-answer]") |> render() =~
             String.trim(evidence)

    assert has_element?(view, selector, "Continuation could not start.")
    assert has_element?(view, selector, "you replied")

    view |> element("#conversation-updates-toggle") |> render_click()

    assert view |> element(selector <> " [data-prior-answer]") |> render() =~
             String.trim(evidence)

    assert has_element?(view, selector, "Continuation could not start.")
  end

  test "an explicit answer equal to historical prompt detail is still rendered", %{
    agent: agent,
    conn: conn
  } do
    detail = "The deployment target is staging."

    message =
      operator_message!(agent.id, "Confirm the deployment target")
      |> Ecto.Changeset.change(
        status: "completed",
        detail: detail,
        result: %{
          "output" => %{
            "directive" => "none",
            "summary" => "Target confirmed.",
            "answer" => detail
          }
        }
      )
      |> Repo.update!()

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    html = view |> element("#exchange-#{message.provider_correlation_id}") |> render()

    assert length(:binary.matches(html, detail)) == 2
  end

  test "the control room links the selected agent to its focused conversation", %{
    agent: agent,
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/console/#{agent.id}")

    assert has_element?(
             view,
             ~s(main a[href="/agents/#{agent.id}/conversation"]),
             "Conversation"
           )
  end

  test "updates toggle preserves direct replies and receives new updates while hidden", %{
    agent: agent,
    conn: conn
  } do
    operator_message!(agent.id, "Please review")
    |> Ecto.Changeset.change(status: "completed", result: %{"output" => "Direct reply"})
    |> Repo.update!()

    Feed.record(%{
      event: "turn",
      agent: agent.id,
      summary: "Scheduled progress",
      origin: "scheduled",
      report: %{"done" => ["Saved [findings](https://example.com/findings)."]}
    })

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    assert has_element?(view, "[data-conversation-update]", "Agent update")

    assert has_element?(
             view,
             ~s([data-conversation-update] a[href="https://example.com/findings"])
           )

    view |> element("#conversation-updates-toggle") |> render_click()
    refute has_element?(view, "[data-conversation-update]")
    assert has_element?(view, "[data-conversation-exchange]", "Direct reply")
    assert has_element?(view, "#message-input-0")

    Feed.record(%{event: "turn", agent: agent.id, summary: "Arrived while hidden"})
    render(view)
    refute has_element?(view, "[data-conversation-update]")
    view |> element("#conversation-updates-toggle") |> render_click()
    assert has_element?(view, "[data-conversation-update]", "Arrived while hidden")

    assert length(
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("[data-conversation-update]")
             |> Enum.to_list()
           ) == 2
  end

  test "long replies keep sanitized Markdown and stable disclosure identities", %{
    agent: agent,
    conn: conn
  } do
    message = operator_message!(agent.id, attachment_prompt())

    answer =
      "**Findings**\n\n- [Evidence](https://example.com/proof)\n\n" <>
        String.duplicate("Complete source text. ", 60)

    message
    |> Ecto.Changeset.change(status: "completed", result: %{"output" => answer})
    |> Repo.update!()

    {:ok, view, html} = live(conn, "/agents/#{agent.id}/conversation")
    assert has_element?(view, "details[phx-hook=DisclosureState] summary", "Show more")
    assert has_element?(view, "details strong", "Findings")
    assert has_element?(view, ~s(details li a[href="https://example.com/proof"]), "Evidence")
    assert html =~ String.duplicate("Complete source text. ", 50)
    assert html =~ "screenshot.png"
    refute html =~ "attached image:"

    disclosures =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("details[phx-hook=DisclosureState]")
      |> LazyHTML.attribute("id")

    assert Enum.all?(disclosures, &String.starts_with?(&1, "answer-"))
    view |> element("#conversation-updates-toggle") |> render_click()

    assert disclosures ==
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("details[phx-hook=DisclosureState]")
             |> LazyHTML.attribute("id")
  end

  test "a scheduled approval stays actionable when updates are hidden", %{
    agent: agent,
    conn: conn
  } do
    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(agent.id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(agent.id) end)
    :processing = Agent.submit_prompt(agent.id, "scheduled sweep")

    result =
      Testing.structured_result(%{
        "directive" => "request_permission",
        "action" => "Review the deployment plan"
      })

    assert_receive {:enqueued, _args, turn_meta}

    :ok =
      Ingest.handle_event(
        [:oban_claude, :run, :stop],
        %{cost_usd: 0.0},
        %{result: result, job: %{meta: turn_meta}},
        nil
      )

    :ok = finish_agent_turn(turn_meta, result)
    {:ok, _status} = Agent.await(agent.id, :awaiting_permission, 1_000)
    eventually(fn -> assert [_gate] = Gates.open_gates(agent.id) end)

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/conversation")
    assert has_element?(view, "#conversation-pending-action", "Review the deployment plan")
    assert has_element?(view, ~s(#conversation-pending-action button[phx-value-op=approve]))
    view |> element("#conversation-updates-toggle") |> render_click()
    refute has_element?(view, "[data-conversation-update]")
    assert has_element?(view, ~s(#conversation-pending-action button[phx-value-op=approve]))
  end

  defp gated_operator_message!(agent_id, output, state, status) do
    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(agent_id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(agent_id) end)
    message = operator_message!(agent_id, "Review the deployment plan")

    :processing =
      Agent.submit_prompt(agent_id, message.prompt,
        origin: :operator,
        correlation_id: message.provider_correlation_id
      )

    assert_receive {:enqueued, _args, turn_meta}
    result = Testing.structured_result(output)
    meta = %{result: result, job: %{meta: turn_meta}}
    measurements = %{cost_usd: 0.0}

    :ok = Ingest.handle_event([:oban_claude, :run, :stop], measurements, meta, nil)
    :ok = OperatorMessages.handle_event([:oban_claude, :run, :stop], measurements, meta, nil)
    :ok = finish_agent_turn(turn_meta, result)
    {:ok, _status} = Agent.await(agent_id, state, 1_000)
    eventually(fn -> assert OperatorMessages.get(message.message_id).status == status end)

    message
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
