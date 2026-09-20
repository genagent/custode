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
    assert html =~ "not a standing rule"
  end

  test "it survives the page's own re-renders and is unique per action" do
    html = render_component(&Components.reject_form/1, agent: "redisctl", action: "act_2435")

    assert html =~ ~s(id="reject-act_2435")
    assert html =~ ~s(phx-update="ignore")
  end
end
