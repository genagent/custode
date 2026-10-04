defmodule CustodeWeb.ChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustodeWeb.Charts

  @first "2026-10-01"
  @quiet "2026-10-02"
  @today "2026-10-03"

  test "daily stacks share the supplied maximum and the legend and table keep its series order" do
    document = render_chart(chart())

    assert text(document, "[data-chart-max]") == "Max 40"
    assert text(document, "[data-chart-baseline]") == "0"

    assert attr(document, ~s([data-chart-day="#{@first}"] [data-chart-series]), "style") ==
             ["height: 25.0%", "height: 15.0%", "height: 10.0%"]

    assert attr(document, ~s([data-chart-day="#{@today}"] [data-chart-series]), "style") ==
             ["height: 50.0%", "height: 30.0%", "height: 20.0%"]

    assert attr(
             document,
             ~s([data-chart-day="#{@first}"] [data-chart-series]),
             "data-chart-series"
           ) ==
             ["Agent: zeta", "Workflow: alpha", "Other"]

    assert text(document, "#daily-test-legend") =~
             ~r/Agent: zeta:.*30.*Workflow: alpha:.*18.*Other:.*12/s

    assert text(document, "#daily-test-values thead") =~
             ~r/Date \(UTC\).*Agent: zeta.*Workflow: alpha.*Other.*Total/s

    assert texts(document, "#daily-test-values tbody tr:first-child td") ==
             ["10 exact", "6 exact", "4 exact", "20 exact"]
  end

  test "a padded day stays visible at zero and today has both text and a shape marker" do
    document = render_chart(chart())

    assert count(document, "[data-chart-day]") == 3
    assert count(document, "[data-chart-zero]") == 1
    assert count(document, ~s([data-chart-day="#{@quiet}"] [data-chart-zero])) == 1
    assert count(document, ~s([data-chart-day="#{@quiet}"] [data-chart-series])) == 0

    assert attr(document, ~s([data-chart-day="#{@quiet}"]), "aria-label") ==
             [
               "#{@quiet}: total 0 exact; Agent: zeta: 0 exact; Workflow: alpha: 0 exact; Other: 0 exact"
             ]

    assert count(document, ~s([data-chart-day="#{@today}"][data-chart-today=true])) == 1
    assert text(document, "figcaption") =~ "↑ Today: #{@today} (UTC)"
    assert text(document, ~s([data-chart-date="#{@today}"])) == "↑03"
    assert text(document, "#daily-test-values tbody tr:last-child th") =~ "#{@today}Today"
  end

  test "an all-zero window labels an actual zero maximum and keeps every day" do
    days =
      for offset <- 13..0//-1 do
        date = Date.add(~D[2026-10-03], -offset) |> Date.to_iso8601()
        %{date: date, total: 0, values: %{}}
      end

    document = render_chart(%{chart() | days: days, series: [], max: 0, total: 0})
    assert text(document, "[data-chart-max]") == "Max 0"
    assert count(document, "[data-chart-zero]") == 14
    assert count(document, "[data-chart-series]") == 0
    assert count(document, "#daily-test-values tbody tr") == 14
    assert text(document, "figure") =~ "No recorded value in this period."
    refute text(document, "figure") =~ "1.0e-9"
  end

  test "compact formatting cannot replace exact values in titles or the keyboard-accessible table" do
    series = [%{key: {:agent, "large"}, kind: :agent, label: "Agent: large", total: 1_234}]
    days = [%{date: @today, total: 1_234, values: %{{:agent, "large"} => 1_234}}]
    values = %{chart() | days: days, series: series, max: 1_234, total: 1_234}

    document = render_chart(values, format: fn _value -> "1k" end, exact_format: &"#{&1} tokens")
    assert text(document, "[data-chart-max]") == "Max 1k"
    assert attr(document, "[data-chart-max]", "title") == ["1234 tokens"]

    assert attr(document, "[data-chart-day]", "aria-label") ==
             ["#{@today} (Today): total 1234 tokens; Agent: large: 1234 tokens"]

    assert text(document, "#daily-test-values") =~ "1234 tokens"
    assert text(document, "#daily-test-values-disclosure > summary") == "Exact daily values"
    assert count(document, "#daily-test-values-disclosure[open]") == 0

    assert count(
             document,
             ~s(#daily-test-values-disclosure [role=region][tabindex="0"].overflow-x-auto)
           ) == 1

    assert count(document, "#daily-test-values th[scope=col]") == 3
    assert count(document, "#daily-test-values th[scope=row]") == 1
  end

  test "turn outcomes retain their meanings even when the supplied ranking puts failures first" do
    series = [
      %{key: :failed, kind: :outcome, label: "Failed", total: 3},
      %{key: :ok, kind: :outcome, label: "Successful", total: 1}
    ]

    days = [%{date: @today, total: 4, values: %{failed: 3, ok: 1}}]

    document =
      render_chart(%{chart() | metric: :turns, series: series, days: days, max: 4, total: 4})

    assert attr(document, "[data-chart-series]", "data-chart-series") == ["Failed", "Successful"]
    assert count(document, ~s([data-chart-series="Failed"].bg-error)) == 1
    assert count(document, ~s([data-chart-series="Successful"].bg-success)) == 1
    assert text(document, "#daily-test-legend") =~ ~r/Failed:.*3.*Successful:.*1/s
  end

  test "fourteen days and all six displayed series retain labels, ordering and exact values" do
    series =
      [%{key: :other, kind: :other, label: "Other", total: 70}] ++
        for n <- 5..1//-1 do
          %{key: {:agent, n}, kind: :agent, label: "Agent: #{n}-long-project-name", total: n * 14}
        end

    values = Map.new(series, &{&1.key, div(&1.total, 14)})

    days =
      for offset <- 13..0//-1 do
        date = Date.add(~D[2026-10-03], -offset) |> Date.to_iso8601()
        %{date: date, total: 20, values: values}
      end

    document = render_chart(%{chart() | days: days, series: series, max: 20, total: 280})
    labels = Enum.map(series, & &1.label)

    assert count(document, "[data-chart-day]") == 14
    assert count(document, "[data-chart-date]") == 14
    assert count(document, "#daily-test-legend li") == 6
    assert count(document, "#daily-test-values tbody tr") == 14

    assert attr(
             document,
             ~s([data-chart-day="#{@today}"] [data-chart-series]),
             "data-chart-series"
           ) == labels

    assert texts(document, "#daily-test-values thead th") == ["Date (UTC)" | labels] ++ ["Total"]
    assert text(document, ~s([data-chart-date="#{@today}"])) == "↑03"
  end

  test "Other in the middle preserves five distinct named colors without changing ranking" do
    named =
      for n <- 5..1//-1 do
        %{key: {:agent, n}, kind: :agent, label: "Agent: #{n}", total: n}
      end

    series = List.insert_at(named, 1, %{key: :other, kind: :other, label: "Other", total: 4})
    values = Map.new(series, &{&1.key, &1.total})
    days = [%{date: @today, total: 19, values: values}]
    document = render_chart(%{chart() | series: series, days: days, max: 19, total: 19})
    labels = Enum.map(series, & &1.label)

    assert attr(document, "[data-chart-series]", "data-chart-series") == labels
    assert texts(document, "#daily-test-values thead th") == ["Date (UTC)" | labels] ++ ["Total"]

    tones =
      document
      |> attr(~s|[data-chart-series]:not([data-chart-series="Other"])|, "class")
      |> Enum.map(fn classes -> classes |> String.split() |> List.last() end)

    assert tones == ~w(bg-primary bg-secondary bg-info bg-success bg-neutral)

    legend_tones =
      document
      |> attr("#daily-test-legend li > span[aria-hidden]", "class")
      |> Enum.map(fn classes -> classes |> String.split() |> List.last() end)

    assert legend_tones == List.insert_at(tones, 1, "bg-base-content/30")
  end

  test "untrusted series labels stay text in chart titles, the legend and the exact table" do
    label = ~s|Agent: <script>alert("x")</script>|
    series = [%{key: {:agent, "hostile"}, kind: :agent, label: label, total: 0.00001}]
    days = [%{date: @today, total: 0.00001, values: %{{:agent, "hostile"} => 0.00001}}]

    document =
      render_chart(
        %{chart() | metric: :usd, series: series, days: days, max: 0.00001, total: 0.00001},
        format: &"#{&1} USD",
        exact_format: &"#{&1} USD"
      )

    assert count(document, "script") == 0
    assert text(document, "#daily-test-legend") =~ label
    assert text(document, "#daily-test-values") =~ label
    assert text(document, "[data-chart-max]") == "Max 1.0e-5 USD"
    assert attr(document, "[data-chart-series]", "style") == ["height: 100.0%"]
  end

  defp chart do
    %{
      metric: :tokens,
      today: @today,
      max: 40,
      total: 60,
      series: [
        %{key: {:agent, "zeta"}, kind: :agent, label: "Agent: zeta", total: 30},
        %{key: {:workflow, "alpha"}, kind: :workflow, label: "Workflow: alpha", total: 18},
        %{key: :other, kind: :other, label: "Other", total: 12}
      ],
      days: [
        %{
          date: @first,
          total: 20,
          values: %{{:agent, "zeta"} => 10, {:workflow, "alpha"} => 6, :other => 4}
        },
        %{date: @quiet, total: 0, values: %{}},
        %{
          date: @today,
          total: 40,
          values: %{{:agent, "zeta"} => 20, {:workflow, "alpha"} => 12, :other => 8}
        }
      ]
    }
  end

  defp render_chart(chart, opts \\ []) do
    assigns = [
      id: "daily-test",
      chart: chart,
      label: "Daily test",
      format: &to_string/1,
      exact_format: &"#{&1} exact"
    ]

    render_component(&Charts.daily_chart/1, Keyword.merge(assigns, opts))
    |> LazyHTML.from_document()
  end

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp texts(document, selector),
    do: document |> LazyHTML.query(selector) |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

  defp attr(document, selector, name),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()
end
