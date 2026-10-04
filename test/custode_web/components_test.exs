defmodule CustodeWeb.ComponentsTest do
  use ExUnit.Case, async: true

  import CustodeWeb.Components

  describe "global attention and local navigation counts" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "the supplied resolver snapshot owns the global count and accessible explanation" do
      signals = [
        %Custode.Signal{
          subject: "one",
          kind: :needs_answer,
          group: :needs_you,
          urgency: :high,
          headline: "question"
        },
        %Custode.Signal{
          subject: "host",
          kind: :host_down,
          group: :needs_you,
          urgency: :high,
          headline: "host"
        },
        %Custode.Signal{
          subject: "quiet",
          kind: :quiet,
          group: :quiet,
          urgency: :normal,
          headline: "resting"
        }
      ]

      header =
        render_component(&app_header/1,
          fleet_today: 0,
          attention_signals: signals,
          unread: 4,
          launch_gates: 1
        )

      chip = render_component(&attention_chip/1, signals: signals)

      for html <- [header, chip] do
        assert html =~ ~s(data-attention-count="2")
        assert html =~ "Attention: 2"
        assert html =~ "one asked you"
        assert html =~ "host cannot run turns"
        assert html =~ "One signal per agent, plus host, repository and"
        assert html =~ "Inbox new items and advisor suggestions are separate."
      end

      document = LazyHTML.from_document(header)
      assert document |> LazyHTML.query(~s(a[href="/inbox"])) |> LazyHTML.text() =~ "4 new"

      assert document |> LazyHTML.query(~s(a[href="/workflows"])) |> LazyHTML.text() =~
               "1 pending launch"

      refute header =~ "1 pending launches"
    end

    test "an explicit empty snapshot stays empty and local counts remain local" do
      html =
        render_component(&app_header/1,
          fleet_today: 0,
          attention_signals: [],
          unread: 3,
          launch_gates: 2
        )

      refute html =~ "data-attention-count"
      assert html =~ "3 new"
      assert html =~ "2 pending launches"
    end
  end

  describe "foldable_text/1" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "short text stays plain" do
      html = render_component(&CustodeWeb.Components.foldable_text/1, text: "a useful sentence")

      assert html =~ "a useful sentence"
      refute html =~ "<details"
      refute html =~ "Show more"
    end

    test "missing text stays plain and empty" do
      html = render_component(&CustodeWeb.Components.foldable_text/1, text: nil)

      assert html =~ "data-foldable-text"
      refute html =~ "<details"
      refute html =~ "Show more"
    end

    test "the preview stops at a complete word and has one separate omission marker" do
      expected = String.duplicate("word ", 54) <> "boundary"
      source = expected <> String.duplicate(" remaining words", 20)
      document = fold_document(source, id: "word-preview", class: "min-w-0 flex-1")

      assert fold_text(document, "[data-foldable-preview-text]") == expected
      assert fold_text(document, "[data-foldable-omission]") == "…"
      assert length(fold_nodes(document, "[data-foldable-omission]")) == 1
      assert length(fold_nodes(document, "#word-preview[data-foldable-text].flex-1")) == 1
      assert fold_text(document, "[data-foldable-full]") == source
    end

    test "a word that ends exactly at the preview budget is retained" do
      expected = String.duplicate("word ", 55) <> "final"
      document = fold_document(expected <> String.duplicate(" next", 30))

      assert String.length(expected) == 280
      assert fold_text(document, "[data-foldable-preview-text]") == expected
    end

    test "the preview stays outside the keyboard-accessible native disclosure control" do
      document = fold_document(String.duplicate("a useful sentence ", 30))

      assert fold_nodes(document, "details[open]") == []
      assert length(fold_nodes(document, "[data-foldable-text] > details > summary")) == 1
      assert fold_nodes(document, "summary [data-foldable-preview]") == []
      assert fold_nodes(document, ".line-clamp-3") == []
      assert fold_text(document, "summary [data-foldable-show-more]") == "Show more"
      assert fold_text(document, "summary [data-foldable-show-less]") == "Show less"
      assert length(fold_nodes(document, "[data-foldable-omission][aria-hidden=true]")) == 1
    end

    test "existing terminal ellipses do not double the preview's omission marker" do
      expected = String.duplicate("word ", 54) |> String.trim_trailing()

      for ending <- ["…", "...", "… ..."] do
        source = expected <> " " <> ending <> " " <> String.duplicate("unbroken", 60)
        document = fold_document(source)

        assert fold_text(document, "[data-foldable-preview-text]") == expected
        assert fold_text(document, "[data-foldable-omission]") == "…"
        assert fold_text(document, "[data-foldable-full]") == source
      end
    end

    test "an unbroken token remains intact for the three-line clip to wrap" do
      source = String.duplicate("longtoken", 60)
      document = fold_document(source)

      assert fold_text(document, "[data-foldable-preview-text]") == source
      assert length(fold_nodes(document, "[data-foldable-omission]")) == 1
      assert fold_text(document, "[data-foldable-full]") == source
    end

    test "multiline source, code and links are preserved in the expanded text" do
      source =
        "line one\nline two\n`code(value)`\nhttps://example.test/?a=1&b=2\n<script>inert</script>\nlast line"

      document = fold_document(source)

      assert fold_text(document, "[data-foldable-preview-text]") == source
      assert length(fold_nodes(document, "[data-foldable-omission]")) == 1
      assert fold_text(document, "[data-foldable-full]") == source
      assert fold_nodes(document, "script") == []
    end

    defp fold_document(text, attrs \\ []) do
      render_component(&CustodeWeb.Components.foldable_text/1, Keyword.merge([text: text], attrs))
      |> LazyHTML.from_document()
    end

    defp fold_nodes(document, selector),
      do: document |> LazyHTML.query(selector) |> Enum.to_list()

    defp fold_text(document, selector),
      do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  describe "usd/1" do
    test "always two decimals" do
      assert usd(7.6782) == "7.68"
      assert usd(20.089) == "20.09"
      assert usd(25.0) == "25.00"
      assert usd(0) == "0.00"
    end
  end

  describe "the ask pair in the feed vocabulary (#445)" do
    test "an asked entry is an attention event, styled below a blocking question" do
      assert feed_category_match?("asked", "attention")
      assert feed_badge("asked") =~ "badge-accent"
      assert feed_badge("asked") =~ "badge-outline"
      refute feed_badge("needs_input") =~ "badge-outline"
      assert event_dot("asked") == "text-accent"
    end

    test "an answered entry is the operator's act, not something waiting on them" do
      refute feed_category_match?("answered", "attention")
      assert feed_badge("answered") =~ "badge-success"
      assert event_dot("answered") == "text-success"
    end
  end

  describe "a failed sensor run in the feed vocabulary (#444)" do
    test "it is drawn as an error, not in the ambient grey of a quiet sensor line" do
      assert feed_badge("sensor_failed") == "badge-error"
      assert event_dot("sensor_failed") == "text-error"
      assert feed_badge("sensor") == "badge-ghost"
    end

    test "it shows under both the attention lens and the sensors lens" do
      assert feed_category_match?("sensor_failed", "attention")
      assert feed_category_match?("sensor_failed", "sensors")
      refute feed_category_match?("sensor", "attention")
    end
  end

  describe "ago_text/1" do
    test "buckets seconds/minutes/hours/days and tolerates junk" do
      now = DateTime.utc_now()
      assert ago_text(DateTime.add(now, -5)) == "5s ago"
      assert ago_text(DateTime.add(now, -300)) == "5m ago"
      assert ago_text(DateTime.add(now, -7200)) == "2h ago"
      assert ago_text(DateTime.add(now, -172_800)) == "2d ago"
      assert ago_text(DateTime.add(now, -90) |> DateTime.to_iso8601()) == "1m ago"
      assert ago_text("not a time") == "not a time"
      assert ago_text(nil) == "?"
    end
  end

  describe "until_text/2" do
    test "buckets the wait, and a time already past is now" do
      now = ~U[2026-09-20 10:00:00Z]
      assert until_text(DateTime.add(now, 40), now) == "40s"
      assert until_text(DateTime.add(now, 720), now) == "12m"
      assert until_text(DateTime.add(now, 3 * 3_600 + 59), now) == "3h"
      assert until_text(DateTime.add(now, 2 * 86_400), now) == "2d"
      assert until_text(now, now) == "now"
      assert until_text(DateTime.add(now, -30), now) == "now"
    end
  end

  describe "markdown rendering" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "tables and code render; raw HTML from agents is inert" do
      table = "| repo | license |\n|------|---------|\n| adrs | Apache-2.0 |"
      html = render_component(&CustodeWeb.Components.markdown/1, text: table)
      assert html =~ "<table"
      assert html =~ "Apache-2.0"

      sneaky = "hello <script>alert(1)</script> `code` world"
      html = render_component(&CustodeWeb.Components.markdown/1, text: sneaky)
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;" or html =~ "&amp;lt;script"
      assert html =~ "<code"
    end
  end

  describe "markdown rendering is inert against hostile agent text (#460)" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    defp md(text), do: render_component(&CustodeWeb.Components.markdown/1, text: text)

    # Quoted attribute values are blanked first: a payload held inside a value
    # by an escaped quote (`&quot;`) is inert, and what is left of the tag
    # shows any attribute that really was injected.
    defp refute_handler_attribute(html) do
      tags_only = String.replace(html, ~r/"[^"]*"/, ~s(""))
      refute tags_only =~ ~r/<[^>]*\son\w+\s*=/i
    end

    test "unsafe link schemes do not reach an href" do
      for target <- [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "vbscript:msgbox(1)",
            "data:text/html,<script>alert(1)</script>"
          ] do
        html = md("[click](#{target})")
        refute html =~ ~r/href="\s*(javascript|vbscript|data):/i
        refute html =~ "<script>"
      end
    end

    test "safe link schemes still render as links" do
      html = md("[pr](https://github.com/genagent/custode/pull/1)")
      assert html =~ ~s(href="https://github.com/genagent/custode/pull/1")
    end

    test "a link title cannot break out of its attribute" do
      for text <- [
            ~s|[x](http://a.b 't" onmouseover="alert(1)')|,
            ~s|[x](http://a.b "t\\" onmouseover=\\"alert(1)")|
          ] do
        html = md(text)
        refute_handler_attribute(html)
      end
    end

    test "image alt, title and src cannot carry a payload" do
      for text <- [
            ~s|![a" onerror="alert(1)](http://a.b/i.png)|,
            ~s|![a](http://a.b/i.png 't" onerror="alert(1)')|
          ] do
        refute_handler_attribute(md(text))
      end

      refute md("![a](javascript:alert(1))") =~ ~r/src="\s*javascript:/i
    end

    test "autolinks and reference-style links get the same scheme check" do
      refute md("<javascript:alert(1)>") =~ ~r/href="\s*javascript:/i

      html = md("[x][r]\n\n[r]: javascript:alert(1) 't\" onmouseover=\"alert(1)'")
      refute html =~ ~r/href="\s*javascript:/i
      refute_handler_attribute(html)
    end

    test "attribute-list syntax does not add attributes" do
      for text <- [
            ~s|[x](http://a.b){: onmouseover="alert(1)"}|,
            ~s|[x](http://a.b){: onmouseover=alert(1)}|,
            ~s|para\n{: onclick="alert(1)"}|
          ] do
        refute_handler_attribute(md(text))
      end
    end

    test "raw HTML is escaped, not rendered" do
      html =
        md("<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\nhi <b onclick=x>b</b>")

      refute html =~ "<script"
      refute html =~ "<img"
      refute html =~ "<b "
      assert html =~ "&lt;script&gt;"
    end

    test "fenced code retains its language class through sanitization (#558)" do
      html = md("```elixir\nIO.puts(\"<hi>\")\n```")

      assert html =~ ~r/<pre[^>]*>\s*<code\b[^>]*class="language-elixir"/
      assert html =~ "&lt;hi&gt;"
      refute html =~ "<hi>"
    end

    test "single newlines break, fenced code and strong render" do
      assert md("a\nb") =~ ~r/a<br\s*\/?>\s*b/

      html = md("**bold**\n\n```elixir\nIO.puts(\"<hi>\")\n```")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<pre"
      assert html =~ "&lt;hi&gt;"
    end
  end

  describe "feed_text/1" do
    test "failure events carry a what-happens-next hint" do
      assert feed_text(%{"event" => "turn_failed", "kind" => "max_turns_exceeded"}) =~
               "re-approving grants a fresh turn budget"

      assert feed_text(%{"event" => "turn_failed", "kind" => "max_budget_exceeded"}) =~
               "max_budget_usd"

      assert feed_text(%{"event" => "turn_failed", "kind" => "timeout"}) =~ "timeout_ms"
      assert feed_text(%{"event" => "turn_failed", "kind" => "weird"}) =~ "next beat retries"
    end

    test "budget_paused explains the rail and the exit" do
      assert feed_text(%{"event" => "budget_paused"}) =~ "human resumes"
    end

    test "ordinary events keep the summary-first fallback chain" do
      assert feed_text(%{"event" => "turn", "summary" => "swept"}) == "swept"
      assert feed_text(%{"event" => "needs_approval", "action" => "rm"}) == "rm"
    end
  end
end
