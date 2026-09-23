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
    path = if page == "custode", do: "/custode", else: "/console/#{worker}?commands=open"

    html =
      build_conn()
      |> get(path)
      |> html_response(200)
      |> String.replace(~s(data-theme="paper"), ~s(data-theme="#{theme}"), global: false)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, html)
    IO.puts("wrote #{output}")

    assert File.read!(output) =~ ~s(data-theme="#{theme}")
  end

  defp preview_theme! do
    case System.get_env("PREVIEW_THEME", "paper") do
      theme when theme in ~w(paper ink) -> theme
      other -> raise "PREVIEW_THEME must be paper or ink, got: #{inspect(other)}"
    end
  end
end
