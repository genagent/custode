defmodule CustodeWeb.PageHeadersTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CustodeWeb.Endpoint

  setup do
    clear_attention!()
    put_env!(:routines, [])
    put_env!(:sensors, [])
    :ok
  end

  test "ordinary routes expose one page title and current summary in the shared frame" do
    for {route, title} <- [
          {"/inbox", "Inbox"},
          {"/repos", "Repos"},
          {"/suggestions", "Suggestions"},
          {"/workflows", "Workflows"},
          {"/metrics", "Metrics"}
        ] do
      {:ok, view, _html} = live(build_conn(), route)
      doc = render(view) |> LazyHTML.from_document()
      headings = doc |> LazyHTML.query("h1") |> Enum.to_list()
      assert length(headings) == 1
      assert has_element?(view, "main#page-content > #page-header h1#page-header-title", title)
      assert has_element?(view, "#page-header[aria-labelledby=page-header-title] p")

      assert has_element?(
               view,
               ~s(#application-header nav[aria-label=primary] a[aria-current=page][href="#{route}"])
             )

      GenServer.stop(view.pid)
    end
  end
end
