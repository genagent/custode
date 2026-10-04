defmodule CustodeWeb.RejectFormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CustodeWeb.Components

  # every surface that can reject a gate draws this, so none of them can send
  # a placeholder reason again (#438)
  test "the form cannot submit without a reason, and offers one-off" do
    html = render_component(&Components.reject_form/1, agent: "redisctl", action: "act_2435")

    assert html =~ ~s(phx-submit="reject")
    assert html =~ ~s(name="agent" value="redisctl")
    assert html =~ ~s(name="action" value="act_2435")
    assert html =~ ~r/<textarea[^>]*name="reason"[^>]*required/
    assert html =~ ~s(name="one_off")
    assert html =~ "This proposal only"
    assert html =~ "Do not make a standing rule."
    assert html |> LazyHTML.from_document() |> text("button[type=submit]") == "Reject"
  end

  test "it survives the page's own re-renders and is unique per action" do
    html = render_component(&Components.reject_form/1, agent: "redisctl", action: "act_2435")

    assert html =~ ~s(id="reject-act_2435")
    assert html =~ ~s(phx-update="ignore")
  end

  test "the rejection reason and one-off option have persistent associated help" do
    document =
      render_component(&Components.reject_form/1, agent: "redisctl", action: "act_reason")
      |> LazyHTML.from_document()

    assert text(document, ~s(label[for="reject-reason-act_reason"])) == "Reason for rejection"
    assert attribute(document, "textarea[name=reason]", "id") == ["reject-reason-act_reason"]

    assert attribute(document, "textarea[name=reason]", "aria-describedby") == [
             "reject-reason-help-act_reason"
           ]

    assert attribute(document, "textarea[name=reason]", "placeholder") == []

    assert text(document, "#reject-reason-help-act_reason") ==
             "The agent reads this reason and may make it a standing rule."

    assert text(document, ~s(label[for="reject-once-act_reason"])) == "This proposal only"

    assert attribute(document, "input[name=one_off]", "aria-describedby") == [
             "reject-once-help-act_reason"
           ]

    assert attribute(document, "input[name=one_off]", "checked") == []
    assert text(document, "#reject-once-help-act_reason") == "Do not make a standing rule."
  end

  test "multiple actions have isolated labels, help and submitted identities" do
    html =
      for action <- ["act_first", "act_second"], into: "" do
        render_component(&Components.reject_form/1, agent: action <> "_agent", action: action)
      end

    document = LazyHTML.from_document(html)
    ids = document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
    assert length(ids) == length(Enum.uniq(ids))

    for action <- ["act_first", "act_second"] do
      scope = LazyHTML.query(document, "#reject-form-#{action}")
      assert attribute(scope, "input[name=action]", "value") == [action]
      assert attribute(scope, "input[name=agent]", "value") == [action <> "_agent"]
      assert text(scope, "#reject-reason-help-#{action}") =~ "The agent reads this reason"
      assert text(scope, ~s(label[for="reject-reason-#{action}"])) == "Reason for rejection"
    end
  end

  test "a caller's Cancel disclosure keeps the same rejection operation" do
    document =
      render_component(&Components.reject_form/1,
        agent: "manager",
        action: "act_cancel",
        label: "Cancel"
      )
      |> LazyHTML.from_document()

    assert text(document, "summary") == "Cancel"
    assert text(document, "button[type=submit]") == "Reject"
    assert attribute(document, "form", "phx-submit") == ["reject"]
  end

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(document, selector, name),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
