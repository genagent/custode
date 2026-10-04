defmodule CustodeWeb.AttentionSnapshotTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Asks
  alias Custode.Gates.Gate
  alias Custode.Repo
  alias Custode.Sensors.CiStatus
  alias Custode.Sensors.CiStatus.Infrastructure
  alias Custode.Workflow.Launch

  @endpoint CustodeWeb.Endpoint

  setup do
    clear_attention!()
    Repo.query!("DELETE FROM feed_entries WHERE event IN ('advisor_suggestion', 'inbox_read')")
    path = Path.join(System.tmp_dir!(), uid("attention-header") <> ".jsonl")
    put_env!(:feed_path, path)
    put_env!(:sensors, [])
    workspace = tmp_workspace!()
    viewer = uid("viewer")
    other = uid("other")

    put_env!(:routines, [
      %{id: viewer, cron: :manual, workspace: workspace, prompt: "inspect"},
      %{id: other, cron: :manual, workspace: workspace, prompt: "inspect"}
    ])

    on_exit(fn ->
      clear_attention!()
      Repo.query!("DELETE FROM feed_entries WHERE event IN ('advisor_suggestion', 'inbox_read')")
      File.rm(path)
    end)

    %{conn: build_conn(), viewer: viewer, other: other}
  end

  for route <- [
        "/repos",
        "/messages",
        "/feed?kind=attention&agent=absent",
        "/workflows",
        "/suggestions",
        "/metrics",
        :conversation
      ] do
    test "#{route} refreshes global attention for another subject without a local interaction", %{
      conn: conn,
      viewer: viewer,
      other: other
    } do
      route = unquote(route)
      path = if route == :conversation, do: "/agents/#{viewer}/conversation", else: route
      {:ok, view, _html} = live(conn, path)
      assert_attention(view, 0)

      # A gate mutation's status notification must reach pages whose own data
      # is unrelated. No feed insertion or local route change rescues this.
      gate = gate!(other)
      Custode.PubSubBridge.broadcast({:status_changed, other})
      eventually(fn -> assert_attention(view, 1) end)

      {:ok, ask} = Asks.ask(other, "another reason on the same subject")

      eventually(fn ->
        assert_attention(view, 1)

        assert has_element?(
                 view,
                 "#application-header [data-attention-count]",
                 "#{other} asked you"
               )
      end)

      {:ok, _ask} = Asks.dismiss(ask.id)

      eventually(fn ->
        assert_attention(view, 1)

        assert has_element?(
                 view,
                 "#application-header [data-attention-count]",
                 "#{other} needs approval"
               )
      end)

      gate |> Ecto.Changeset.change(status: "resolved") |> Repo.update!()
      Custode.PubSubBridge.broadcast({:status_changed, other})
      eventually(fn -> assert_attention(view, 0) end)

      if route == :conversation do
        assert has_element?(view, "#conversation-empty")
        assert has_element?(view, ~s(#message-0[data-subject="#{viewer}"]))
        refute has_element?(view, "#conversation-actions")
      end

      if route == "/feed?kind=attention&agent=absent" do
        refute has_element?(view, "#feed li")
      end
    end
  end

  test "Inbox new items and workflow launch badges do not redefine global attention", %{
    conn: conn,
    other: other
  } do
    before = DateTime.add(DateTime.utc_now(), -3600)

    Repo.insert!(%Custode.Feed.Entry{
      event: "inbox_read",
      agent: "operator",
      at: before,
      entry: Jason.encode!(%{event: "inbox_read", at: DateTime.to_iso8601(before)})
    })

    {:ok, _first} = Asks.ask(other, "first question")
    {:ok, _second} = Asks.ask(other, "second question")
    gate!(other)
    workflow = workflow_fixture!(uid("attention-workflow"))
    {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo", why: "review this launch")

    Custode.Feed.record(%{
      event: "advisor_suggestion",
      agent: other,
      advisor: "advisor-cadence",
      field: "cron",
      current: "@daily",
      proposed: "@hourly"
    })

    {:ok, inbox, _html} = live(conn, "/inbox")
    assert_attention(inbox, 2)
    assert has_element?(inbox, ~s(#application-header a[href="/inbox"]), "3 new")

    # A mounted page keeps its arrival boundary, including after another tab
    # marks read. A new visit uses the new boundary; neither resolves a signal.
    {:ok, reopened, _html} = live(build_conn(), "/inbox")
    assert_attention(reopened, 2)
    refute has_element?(reopened, ~s(#application-header a[href="/inbox"] span))
    Custode.PubSubBridge.broadcast({:status_changed, other})

    eventually(fn ->
      assert has_element?(inbox, ~s(#application-header a[href="/inbox"]), "3 new")
    end)

    {:ok, workflows, _html} = live(build_conn(), "/workflows")
    assert_attention(workflows, 2)

    assert has_element?(
             workflows,
             ~s(#application-header a[href="/workflows"]),
             "1 pending launch"
           )

    refute has_element?(
             workflows,
             ~s(#application-header a[href="/workflows"]),
             "1 pending launches"
           )
  end

  test "first Inbox visit has no new badge and a failed host contributes once", %{conn: conn} do
    Custode.Host.put_doctor({:failed, "CLI needs login"})
    {:ok, inbox, _html} = live(conn, "/inbox")
    assert_attention(inbox, 1)
    assert has_element?(inbox, "li", "host down")
    refute has_element?(inbox, ~s(#application-header a[href="/inbox"] span))
  end

  test "repository notifications refresh Inbox rows together with its global snapshot", %{
    conn: conn,
    other: other
  } do
    repo = "owner/#{uid("repository")}"
    sensor = uid("ci")
    args = %{"sensor_id" => sensor, "notify" => other, "repo" => repo}

    put_env!(:sensors, [
      %{id: sensor, cron: "@hourly", module: CiStatus, notify: other, args: %{repo: repo}}
    ])

    {:ok, inbox, _html} = live(conn, "/inbox")
    assert_attention(inbox, 0)
    :ok = Infrastructure.replace(args, [%{kind: :pr, number: 9, head_sha: "head-9"}], 5)
    Custode.PubSubBridge.broadcast({:repo_overview, repo})

    eventually(fn ->
      assert_attention(inbox, 1)
      assert has_element?(inbox, "li", repo)
    end)

    :ok = Infrastructure.replace(args, [], 5)
    Custode.PubSubBridge.broadcast({:repo_overview, repo})

    eventually(fn ->
      assert_attention(inbox, 0)
      refute has_element?(inbox, "li", repo)
      assert render(inbox) =~ "Nothing needs you"
    end)
  end

  defp gate!(agent) do
    Repo.insert!(%Gate{
      agent_id: agent,
      kind: "approval",
      action_id: uid("act"),
      detail: "publish"
    })
  end

  defp assert_attention(view, 0),
    do: refute(has_element?(view, "#application-header [data-attention-count]"))

  defp assert_attention(view, count),
    do: assert(has_element?(view, ~s(#application-header [data-attention-count="#{count}"])))
end
