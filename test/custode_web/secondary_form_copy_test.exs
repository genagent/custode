defmodule CustodeWeb.SecondaryFormCopyTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Custode.Signal
  alias CustodeWeb.Console.{Item, NewAgent, Rail, Subject}

  test "answer and dismissal keep separate operations with visible associated guidance" do
    signal =
      signal([
        %{op: :answer_ask, label: "Answer", args: %{ask: 42, replies: ["Keep My CASE"]}},
        %{op: :dismiss_ask, label: "Dismiss", args: %{ask: 42}}
      ])

    document =
      render_component(&Item.conversation_actions/1, signal: signal, message_gen: 7)
      |> LazyHTML.from_document()

    reply = LazyHTML.query(document, "#reply-answer_ask-7")
    dismiss = LazyHTML.query(document, "#dismiss-ask-42-7")
    assert text(reply, "label[for=reply-text-answer_ask-7]") == "Your answer"
    assert attribute(reply, "textarea[name=text]", "id") == ["reply-text-answer_ask-7"]
    assert attribute(reply, "textarea", "aria-describedby") == ["reply-help-answer_ask-7"]
    assert text(reply, "#reply-help-answer_ask-7") == "Send an answer to this question."
    assert count(reply, "textarea[required]") == 1
    assert attribute(reply, "input[name=op]", "value") == ["answer_ask"]
    assert text(reply, "button[type=submit]") == "Answer"

    assert text(dismiss, "label[for=dismiss-reason-42-7]") == "Reason for dismissal (optional)"
    assert attribute(dismiss, "input[name=reason]", "aria-describedby") == ["dismiss-help-42-7"]

    assert text(dismiss, "#dismiss-help-42-7") ==
             "Dismisses the question without sending an answer."

    assert count(dismiss, "[required]") == 0
    assert attribute(dismiss, "input[name=op]", "value") == ["dismiss_ask"]
    assert attribute(dismiss, "input[name=ask_id]", "value") == ["42"]
    assert text(dismiss, "button[type=submit]") == "Dismiss"
    assert count(document, "[placeholder]") == 0
    assert text(document, "#suggested-replies button") == "Keep My CASE"
    assert attribute(document, "#suggested-replies button", "phx-value-index") == ["0"]
  end

  test "operation labels preserve their authored case and operation identity" do
    document =
      render_component(&Item.conversation_actions/1,
        signal: signal([%{op: :recover_gate, label: "Requeue PR for GitHub", args: %{}}]),
        message_gen: 0
      )
      |> LazyHTML.from_document()

    assert text(document, "button") == "Requeue PR for GitHub"
    assert attribute(document, "button", "phx-value-op") == ["recover_gate"]
  end

  test "a populated fleet filter keeps its label and supported search guidance" do
    document =
      render_component(&Rail.rail/1,
        groups: [],
        filter: "repo:acme/widgets",
        in_flight: %{},
        quiet_open: false
      )
      |> LazyHTML.from_document()

    assert text(document, "label[for=rail-filter-query]") == "Filter subjects"
    assert attribute(document, "input[name=q]", "value") == ["repo:acme/widgets"]
    assert attribute(document, "input[name=q]", "aria-describedby") == ["rail-filter-help"]
    assert text(document, "#rail-filter-help") == "Filter by name, repository, tag, or state."
    assert attribute(document, "#rail-filter", "phx-change") == ["filter"]
    assert attribute(document, "#rail-filter", "phx-submit") == ["filter"]
    assert count(document, "input[placeholder]") == 0
    assert text(document, "button[phx-click=new_open]") == "New agent"
  end

  test "prefilled setup fields retain labels, examples, and unchanged submitted values" do
    params = %{
      "kind" => "bespoke",
      "id" => "My-agent",
      "provider" => "codex",
      "profile" => "",
      "cadence" => "custom",
      "cron" => "0 8 * * *",
      "repo" => "acme/widgets",
      "checkout_mode" => "existing",
      "working_dir" => "/home/me/projects/widgets",
      "model" => "CustomMODEL",
      "effort" => "high",
      "tags" => "API, Rust",
      "prompt" => "Preserve My Prompt CASE"
    }

    document =
      render_component(&NewAgent.new_agent_form/1,
        new_agent: %{choosing: false, params: params, error: nil, browser: nil, plan: nil}
      )
      |> LazyHTML.from_document()

    for {field, label, guidance} <- [
          {"id", "Agent ID", "my-agent"},
          {"cron", "Custom cron", "*/30 9-18 * * 1-5"},
          {"repo", "Repository", "owner/name"},
          {"model", "Model override", "profile or provider default"},
          {"tags", "Tags", "Separate tags with commas"},
          {"prompt", "Standing prompt", "what this agent owns"}
        ] do
      selector = ~s([name="routine[#{field}]"])
      assert count(document, "label #{selector}") == 1
      assert text(document, "label") =~ label
      assert attribute(document, selector, "aria-describedby") == ["new-agent-#{field}-help"]
      assert text(document, "#new-agent-#{field}-help") =~ guidance
      assert field_value(document, selector, field) == params[field]
    end

    assert text(document, "label[for=new-agent-working-dir]") == "Checkout path"
    assert attribute(document, "#new-agent-working-dir", "value") == [params["working_dir"]]

    assert attribute(document, "#new-agent-working-dir", "aria-describedby") == [
             "new-agent-working-dir-help"
           ]

    assert text(document, "#new-agent-working-dir-help") =~ "absolute path on this Custode host"
    assert count(document, ~s(input[name="routine[id]"][required])) == 1
    assert count(document, "[required]") == 1
    assert count(document, "[placeholder]") == 0
    assert attribute(document, "#new-routine", "phx-change") == ["new_change"]
    assert attribute(document, "#new-routine", "phx-submit") == ["new_create"]
    assert attribute(document, ~s(input[name="routine[kind]"]), "value") == ["bespoke"]

    assert count(document, ~s(select[name="routine[provider]"] option[value=codex][selected])) ==
             1

    assert text(document, "button[type=submit]") == "Create"
    assert text(document, "button[phx-click=new_browse]") == "Browse host"
  end

  test "disown fields explain ownership and keep the optional reason separate from the number" do
    subject = %{
      id: uid("copy-subject"),
      routine: nil,
      kind: :other,
      state: :offline,
      status: :offline,
      conversation: %{current: nil},
      pending_wake: nil,
      repo: "acme/widgets",
      workflow_gates: %{},
      overview: nil,
      disowned: []
    }

    document =
      render_component(&Subject.subject/1,
        subject: subject,
        signal: nil,
        tab: "work",
        message_gen: 3,
        upload: %Phoenix.LiveView.UploadConfig{}
      )
      |> LazyHTML.from_document()

    form = LazyHTML.query(document, "#disown-3")
    assert text(form, "label[for=disown-number-3]") == "Pull request number"
    assert text(form, "label[for=disown-reason-3]") == "Reason (optional)"
    assert count(form, "input[name=number][required][inputmode=numeric]") == 1
    assert count(form, "input[name=reason][required]") == 0
    assert attribute(form, "input[name=number]", "aria-describedby") == ["disown-help-3"]
    assert attribute(form, "input[name=reason]", "aria-describedby") == ["disown-help-3"]
    assert text(form, "#disown-help-3") =~ "human-owned"
    assert text(form, "#disown-help-3") =~ "Failing checks will need your attention"
    assert attribute(document, "#disown-3", "phx-submit") == ["disown"]
    assert count(form, "[placeholder]") == 0
    assert text(form, "button[type=submit]") == "Disown"
    assert text(document, "button[phx-value-tab=work]") == "Work"
  end

  defp signal(operations) do
    %Signal{
      subject: "project-agent",
      kind: :needs_answer,
      group: :needs_you,
      urgency: :normal,
      headline: "Agent-authored question?",
      resolving: operations
    }
  end

  defp field_value(document, selector, "prompt"), do: text(document, selector)

  defp field_value(document, selector, _field),
    do: document |> attribute(selector, "value") |> hd()

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(document, selector, name),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
