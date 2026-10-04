defmodule CustodeWeb.Console.ComposerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustodeWeb.Console.Composer

  test "persistent labels and help explain sending in each agent state" do
    for {state, action, explanation} <- [
          {:offline, "Start and send", "Sending starts a turn with your message."},
          {:paused, "Resume and send", "Sending resumes this paused agent with your message."},
          {:running, "Queue message", "Your message will be queued after its current turn."},
          {:waiting_for_user, "Answer", "The agent is waiting for your answer."},
          {:idle, "Send", "Send a message to continue"}
        ] do
      html =
        render_component(&Composer.message_composer/1,
          subject_id: "project-agent",
          state: state,
          message_gen: 7,
          upload: %Phoenix.LiveView.UploadConfig{}
        )

      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("label[for=message-input-7]") |> LazyHTML.text() =~
               "Message project-agent"

      assert document |> LazyHTML.query("#message-help-7") |> LazyHTML.text() =~ explanation
      assert document |> LazyHTML.query("button[type=submit]") |> LazyHTML.text() =~ action

      assert document
             |> LazyHTML.query("textarea[aria-describedby=message-help-7]")
             |> Enum.count() == 1

      assert document |> LazyHTML.query("textarea[placeholder]") |> Enum.count() == 0
    end
  end

  test "attachment and sending share one action row without changing draft or upload ownership" do
    upload = %Phoenix.LiveView.UploadConfig{name: :image, ref: "image-upload", accept: [".png"]}

    document =
      render_component(&Composer.message_composer/1,
        subject_id: "project-agent",
        state: :idle,
        routine: %{id: "project-agent"},
        message_gen: 8,
        upload: upload
      )
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("[data-composer-actions] input[type=file]") |> Enum.count() ==
             1

    assert document
           |> LazyHTML.query("[data-composer-actions] button[type=submit]")
           |> Enum.count() == 1

    assert document |> LazyHTML.query("input[type=file]") |> Enum.count() == 1
    assert document |> LazyHTML.query("label") |> LazyHTML.text() =~ "Attach image"

    assert document
           |> LazyHTML.query("form[phx-hook=SubjectDraft][phx-submit=message]")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("[phx-drop-target=image-upload] textarea[data-draft-input]")
           |> Enum.count() == 1
  end
end
