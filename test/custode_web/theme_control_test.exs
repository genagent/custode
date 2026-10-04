defmodule CustodeWeb.ThemeControlTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustodeWeb.Components

  test "the compact theme control is a native toggle with an explicit current-mode description" do
    document = render_component(&Components.theme_toggle/1, %{}) |> LazyHTML.from_document()

    assert attribute(document, "button", "type") == ["button"]
    assert attribute(document, "button", "aria-label") == ["Dark theme"]
    assert attribute(document, "button", "aria-pressed") == ["false"]
    assert attribute(document, "button", "aria-describedby") == ["theme-current"]

    assert attribute(document, "button", "title") == [
             "Current theme: Paper (light). Switch to Ink (dark)."
           ]

    assert text(document, "#theme-current") == "Current theme: Paper (light)."
    assert attribute(document, "button", "phx-hook") == ["ThemeToggle"]
    assert attribute(document, "button", "phx-click") == []
  end

  test "the two mode icons are decorative and use the theme's current text color" do
    document = render_component(&Components.theme_toggle/1, %{}) |> LazyHTML.from_document()

    assert attribute(document, "svg", "data-theme-icon") == ["paper", "ink"]
    assert attribute(document, "svg", "aria-hidden") == ["true", "true"]
    assert attribute(document, "svg", "focusable") == ["false", "false"]
    assert attribute(document, "svg", "stroke") == ["currentColor", "currentColor"]
  end

  test "the shared header has one mode control and one current-mode description" do
    document =
      render_component(&Components.app_header/1, fleet_today: 0, attention_signals: [])
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#application-header [data-theme-toggle]") |> Enum.count() ==
             1

    assert document |> LazyHTML.query("#theme-current") |> Enum.count() == 1
  end

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(document, selector, name),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
