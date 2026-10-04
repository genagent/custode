defmodule CustodeWeb.SharedUITest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import CustodeWeb.Components
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "operator buttons preserve submission, disabled and event semantics" do
    doc = render_component(&controls/1, %{}) |> LazyHTML.from_document()

    assert attribute(doc, "#cancel", "type") == ["button"]
    assert attribute(doc, "#send", "type") == ["submit"]
    assert attribute(doc, "#send", "form") == ["reply"]
    assert attribute(doc, "#send", "phx-disable-with") == ["Sending..."]
    assert doc |> LazyHTML.query("#disabled[disabled]") |> Enum.count() == 1
    assert attribute(doc, "#approve", "phx-click") == ["approve"]
    assert attribute(doc, "#approve", "phx-value-action") == ["server-action"]
    assert attribute(doc, "#approve", "data-confirm") == ["Approve this plan?"]
    assert text(doc, "#approve") == "Approve"
    assert text(doc, "#reject") == "Reject"
  end

  test "an informational token never claims running activity without that state" do
    doc = render_component(&tokens/1, %{}) |> LazyHTML.from_document()
    assert text(doc, "#observing") == "observing"
    assert doc |> LazyHTML.query("#observing [data-running-indicator]") |> Enum.count() == 0
    assert text(doc, "#running") == "running"
    assert attribute(doc, "#running [data-running-indicator]", "aria-hidden") == ["true"]

    for label <- ~w(warning success error neutral) do
      assert text(doc, "##{label}") == label
    end
  end

  test "lifecycle tokens keep the shared vocabulary and one requested size" do
    for state <- statuses() do
      doc =
        render_component(&status_badge/1, status: state, size: "badge-xs")
        |> LazyHTML.from_document()

      assert LazyHTML.text(doc) |> String.trim() == status_label(state)

      assert doc |> LazyHTML.query("[data-running-indicator]") |> Enum.count() ==
               if(state == :running, do: 1, else: 0)

      refute render_component(&status_badge/1, status: state, size: "badge-xs") =~ "badge-sm"
    end
  end

  test "the ordinary header has a named heading, summary and native optional action" do
    doc = render_component(&heading/1, %{}) |> LazyHTML.from_document()
    assert text(doc, "h1") == "Reports <today>"
    assert text(doc, "#page-header p") == "3 reports ready to read."
    assert attribute(doc, "#page-header", "aria-labelledby") == ["page-header-title"]
    assert attribute(doc, "#page-header h1", "id") == ["page-header-title"]
    assert attribute(doc, "#page-header a", "href") == ["/reports/export"]
    assert doc |> LazyHTML.query("h1 today") |> Enum.count() == 0
  end

  defp controls(assigns) do
    ~H"""
    <.action_button id="cancel" variant={:quiet}>Cancel</.action_button>
    <.action_button id="send" type="submit" variant={:primary} form="reply" phx-disable-with="Sending...">Send</.action_button>
    <.action_button id="disabled" disabled>Unavailable</.action_button>
    <.action_button id="approve" variant={:primary} phx-click="approve" phx-value-action="server-action" data-confirm="Approve this plan?">Approve</.action_button>
    <.action_button id="reject" variant={:destructive}>Reject</.action_button>
    """
  end

  defp tokens(assigns) do
    ~H"""
    <.status_token id="observing" tone={:info}>observing</.status_token>
    <.status_token id="running" tone={:info} running>running</.status_token>
    <.status_token :for={tone <- [:warning, :success, :error, :neutral]} id={tone} tone={tone}>{tone}</.status_token>
    """
  end

  defp heading(assigns) do
    ~H"""
    <.page_header title="Reports <today>" summary="3 reports ready to read.">
      <:action><a href="/reports/export" class={action_classes(:secondary)}>Export reports</a></:action>
    </.page_header>
    """
  end

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attribute(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
