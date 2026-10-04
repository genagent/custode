defmodule CustodeWeb.SharedControlCopyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustodeWeb.Components

  test "the restore control uses sentence case without rewriting the saved prompt" do
    prompt = "keep THIS operator text"

    document =
      render_component(&Components.feed_entry/1,
        entry: %{"event" => "prompted", "agent" => "project", "prompt" => prompt},
        restore_prompt: true
      )
      |> LazyHTML.from_document()

    button = LazyHTML.query(document, "button[phx-click=restore_message]")
    assert button |> LazyHTML.text() |> String.trim() == "Edit and send again"
    assert LazyHTML.attribute(button, "phx-value-text") == [prompt]
  end

  test "suggestion controls use sentence case while their proposed value remains exact" do
    proposed = "*/30 9-18 * * *"

    document =
      render_component(&Components.suggestion_card/1,
        suggestion: %{
          "agent" => "project",
          "field" => "cron",
          "current" => "@daily",
          "proposed" => proposed
        }
      )
      |> LazyHTML.from_document()

    for {event, label} <- [{"apply_suggestion", "Apply"}, {"dismiss_suggestion", "Dismiss"}] do
      button = LazyHTML.query(document, "button[phx-click=#{event}]")
      assert button |> LazyHTML.text() |> String.trim() == label
      assert LazyHTML.attribute(button, "phx-value-proposed") == [proposed]
      assert LazyHTML.attribute(button, "phx-value-agent") == ["project"]
    end
  end
end
