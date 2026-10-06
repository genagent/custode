defmodule Custode.MCP.ReferenceTest do
  use ExUnit.Case, async: true

  alias Custode.MCP.CallContext, as: Frame
  alias Custode.MCP.{Reference, Server}

  defp notes, do: "docs/mcp/behavior.json" |> File.read!() |> Jason.decode!()

  test "checked-in artifacts match discovery and reviewed behavior" do
    for {path, expected} <- Reference.documents() do
      assert File.read!(path) == expected, "#{path} is stale; run mix custode.mcp.docs"
    end
  end

  test "public schemas and runtime resources survive export unchanged" do
    catalog = Reference.catalog(notes())
    frame = %Frame{assigns: %{custode_identity: %{kind: :operator}}}

    for {kind, method} <- [
          {"tools", "tools/list"},
          {"resources", "resources/list"},
          {"resourceTemplates", "resources/templates/list"}
        ] do
      definitions =
        Reference.discovery_pages(kind, fn params ->
          {:reply, result, _} = Custode.TestHelpers.mcp_dispatch(method, params, frame, Server)
          result
        end)

      for definition <- definitions do
        exported = Enum.find(catalog[kind], &(&1["name"] == definition["name"]))
        assert exported["definition"] == definition
      end
    end

    # Dynamic operator resources must not disappear from a static-component
    # export; neither should the narrow endpoint inherit them.
    assert catalog["resources"] != []
    memory = Enum.find(catalog["endpoints"], &(&1["path"] == "/mcp/memory"))
    assert memory["resources"] == []
    assert memory["resourceTemplates"] == []

    assert memory["tools"] |> Enum.sort() ==
             ~w(forget integration_list journal_read recall remember return_context subject_context)
  end

  test "the catalog includes every registered tool across default discovery pages" do
    catalog = Reference.catalog(notes())
    main = Enum.find(catalog["endpoints"], &(&1["path"] == "/mcp"))
    expected = Server.tools() |> Enum.map(& &1.name()) |> Enum.sort()
    assert length(expected) > 100
    assert main["tools"] == expected
    assert Enum.sort(Enum.map(catalog["tools"], & &1["name"])) == expected
  end

  test "every discovery kind follows cursors even across an empty page" do
    for kind <- ~w(tools resources resourceTemplates prompts) do
      assert [%{"name" => "first"}, %{"name" => "last"}] =
               Reference.discovery_pages(kind, fn params ->
                 case params["cursor"] do
                   nil -> %{kind => [%{"name" => "first"}], "nextCursor" => "middle"}
                   "middle" -> %{kind => [], "nextCursor" => "last"}
                   "last" -> %{kind => [%{"name" => "last"}]}
                 end
               end)
    end
  end

  test "repeated or invalid discovery cursors fail instead of looping or truncating" do
    for kind <- ~w(tools resources resourceTemplates prompts) do
      assert_raise ArgumentError, ~r/repeated a pagination cursor/, fn ->
        Reference.discovery_pages(kind, fn _params -> %{kind => [], "nextCursor" => "again"} end)
      end

      for cursor <- ["", 123] do
        assert_raise ArgumentError, ~r/invalid pagination cursor/, fn ->
          Reference.discovery_pages(kind, fn _params -> %{kind => [], "nextCursor" => cursor} end)
        end
      end
    end
  end

  test "missing, stale and blank semantics fail instead of producing incomplete documentation" do
    for kind <- ~w(tools resources resourceTemplates),
        name = notes()[kind] |> Map.keys() |> hd() do
      incomplete = update_in(notes(), [kind], &Map.delete(&1, name))

      assert_raise ArgumentError, ~r/behavior coverage: missing/, fn ->
        Reference.catalog(incomplete)
      end

      blank = put_in(notes(), [kind, name, "effects"], " ")

      assert_raise ArgumentError, ~r/needs a reviewed description/, fn ->
        Reference.catalog(blank)
      end
    end

    for kind <- ~w(tools resources resourceTemplates prompts) do
      stale = put_in(notes(), [kind, "removed_capability"], %{})

      assert_raise ArgumentError, ~r/stale.*removed_capability/, fn ->
        Reference.catalog(stale)
      end
    end
  end

  test "Markdown retains literal placeholders while JSON retains their original strings" do
    files = Reference.documents()
    markdown = files["docs/mcp-reference.md"]
    assert markdown =~ "workspaces/&lt;id&gt;"
    assert markdown =~ "blocked: &lt;reason&gt;"
    refute markdown =~ "workspaces/<id>"
    assert files["docs/mcp-reference.json"] =~ "workspaces/<id>"
  end

  test "schema required fields are sets even when discovery emits a different order" do
    first = %{"inputSchema" => %{"required" => ["prompt", "agent_id"]}}
    second = %{"inputSchema" => %{"required" => ["agent_id", "prompt"]}}
    assert Reference.json(first) == Reference.json(second)
  end

  test "canonical JSON is stable for reordered nested objects and preserves scalar types" do
    a = %{"z" => [%{"b" => nil, "a" => false}], "a" => 1.25}
    b = Map.new([{"a", 1.25}, {"z", [Map.new([{"a", false}, {"b", nil}])]}])
    assert Reference.json(a) == Reference.json(b)
    assert Jason.decode!(Reference.json(a)) == a
  end
end
