defmodule CustodeWeb.HostBannerTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Host

  @endpoint CustodeWeb.Endpoint
  @report ~s(claude auth: %{"loggedIn" => false})

  setup do
    path = Path.join(System.tmp_dir!(), uid("host-banner") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    Host.reset()
    on_exit(&Host.reset/0)

    %{conn: build_conn()}
  end

  test "a healthy or unknown host draws no banner", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/inbox")
    refute html =~ "the boot doctor failed"
  end

  # the 2026-09-14 boot: three days of a fleet that could not run and a
  # dashboard that did not say so (#443)
  for path <- ["/", "/inbox", "/metrics", "/suggestions"] do
    test "a failed doctor is on #{path}", %{conn: conn} do
      Host.put_doctor({:failed, @report})

      {:ok, _view, html} = live(conn, unquote(path))

      assert html =~ "no agent can run: the boot doctor failed"
      assert html =~ "Ticks are withheld"
      assert html =~ "loggedIn"
    end
  end

  test "the inbox lists it first, labelled, with no buttons of its own", %{conn: conn} do
    Host.put_doctor({:failed, @report})

    {:ok, _view, html} = live(conn, "/inbox")

    assert html =~ "host down"
    refute html =~ "Nothing needs you"
  end

  test "the header chip includes host attention", %{conn: conn} do
    Host.put_doctor({:failed, @report})

    {:ok, view, html} = live(conn, "/inbox")

    assert has_element?(view, "[data-attention-count]")
    assert html =~ "Attention:"
  end
end
