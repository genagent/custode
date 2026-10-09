defmodule CustodeWeb.DashboardPreviewTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest

  @endpoint CustodeWeb.Endpoint
  @moduletag :preview

  test "writes a standalone themed dashboard fixture" do
    workspace = tmp_workspace!()
    caretaker = uid("custode")
    worker = uid("worker")
    researcher = uid("coastal-research")

    put_env!(:routines, [
      %{
        id: caretaker,
        cron: "@daily",
        workspace: workspace,
        prompt: "care for the fleet",
        role: :caretaker,
        tags: [:meta]
      },
      %{
        id: worker,
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep",
        repo: "acme/widgets"
      },
      %{
        id: researcher,
        cron: "@weekly",
        workspace: workspace,
        prompt: "Investigate travel options"
      }
    ])

    Custode.Feed.record(%{
      event: "turn",
      agent: worker,
      summary: "Reviewed the backlog and saved the next implementation slice."
    })

    {:ok, _ask} = Custode.Asks.ask(worker, "Which release should this target?")

    page = System.get_env("PREVIEW_PAGE", "console")
    theme = preview_theme!()
    output = System.get_env("PREVIEW_OUT", "tmp/#{page}-preview.html")
    path = preview_path(page, worker, researcher)

    html =
      build_conn()
      |> get(path)
      |> html_response(200)
      |> String.replace(~s(data-theme="paper"), ~s(data-theme="#{theme}"), global: false)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, html)

    if page == "workstreams" do
      detail = build_conn() |> get("/workstreams/#{researcher}") |> html_response(200)
      File.write!(Path.join(Path.dirname(output), "workstream-detail.html"), detail)
    end

    IO.puts("wrote #{output}")

    assert File.read!(output) =~ ~s(data-theme="#{theme}")
  end

  defp preview_path(page, worker, researcher) when page in ~w(workstreams workstream) do
    human = %{kind: :operator, id: "preview-human"}

    for {owner, outcome} <- [
          {worker, "Ship the parser fix with a focused regression"},
          {researcher, "Compare quiet coastal bases for November"}
        ] do
      {:ok, receipt} =
        Custode.WorkAgreements.create(human, %{
          request_id: uid("preview-agreement"),
          routine_id: owner,
          intent: %{
            outcome: outcome,
            assignment_id: uid("assignment"),
            criteria: [%{id: "proof", text: "Record evidence and limits"}]
          }
        })

      {:ok, _} =
        Custode.WorkAgreements.checkpoint(human, receipt["agreement_id"], %{
          request_id: uid("preview-checkpoint"),
          expected_revision: 1,
          summary: "Scope recorded; one bounded step remains",
          next_steps: [%{id: "check", text: "Check the remaining evidence", references: []}]
        })
    end

    Custode.Feed.record(%{
      event: "turn",
      agent: researcher,
      summary:
        "Compared three coastal bases. Two fit the quiet-season brief; winter transport remains uncertain.",
      report: %{
        done: ["Saved the comparison with sources"],
        verified: ["Published timetables checked; winter service not confirmed"],
        next: ["Ask for travel dates before narrowing the choice"]
      }
    })

    if System.get_env("PREVIEW_STRESS") == "1" do
      Custode.Feed.record(%{event: "turn", agent: worker, summary: String.duplicate("x", 250)})

      Custode.Feed.record(%{
        event: "turn",
        agent: researcher,
        summary:
          "| Very long heading | Another column | Third column | Fourth column |\n| --- | --- | --- | --- |\n| Example | Example | Example | Example |"
      })
    end

    if page == "workstream", do: "/workstreams/#{researcher}", else: "/"
  end

  defp preview_path("custode", _worker, _researcher), do: "/custode"
  defp preview_path(_page, worker, _researcher), do: "/console/#{worker}?commands=open"

  defp preview_theme! do
    case System.get_env("PREVIEW_THEME", "paper") do
      theme when theme in ~w(paper ink) -> theme
      other -> raise "PREVIEW_THEME must be paper or ink, got: #{inspect(other)}"
    end
  end
end
