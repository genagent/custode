defmodule Custode.MCP.Reference do
  @moduledoc """
  Builds the client reference from discovery definitions and reviewed behavior
  notes. Only registration is inspected: no application, tool, resource read,
  credential lookup, or live connection is needed.
  """

  alias Anubis.Server.{Frame, Handlers}
  alias Custode.MCP.{MCPEx, MemoryServer, Server, ToolPolicy, WorkResources}

  @servers [{"/mcp", Server}, {"/mcp/memory", MemoryServer}]
  @kinds ~w(tools resources resourceTemplates prompts)
  @fields ~w(result effects access notes)

  @doc "Return deterministic output paths and contents relative to the project root."
  def documents(root \\ File.cwd!()) do
    notes = root |> Path.join("docs/mcp/behavior.json") |> File.read!() |> Jason.decode!()
    overview = root |> Path.join("docs/mcp/overview.md") |> File.read!()
    catalog = catalog(notes)

    %{
      "docs/mcp-reference.md" => markdown(catalog, overview),
      "docs/mcp-reference.json" => json(catalog) <> "\n"
    }
  end

  @doc "Collect registered definitions and require an exact, nonempty semantic inventory."
  def catalog(notes) do
    if Enum.sort(ToolPolicy.servers()) != Enum.sort(Enum.map(@servers, &elem(&1, 1))) do
      raise ArgumentError, "update the MCP reference endpoint adapter for registered servers"
    end

    endpoints = Enum.map(@servers, &endpoint/1)

    Enum.reduce(@kinds, %{"formatVersion" => 1, "endpoints" => endpoint_index(endpoints)}, fn
      kind, acc ->
        entries = merge_definitions(endpoints, kind)
        behavior = Map.fetch!(notes, kind)
        validate_notes!(kind, entries, behavior)
        enriched = Enum.map(entries, &Map.put(&1, "behavior", Map.fetch!(behavior, &1["name"])))
        Map.put(acc, kind, enriched)
    end)
  end

  # WorkResources.register is the same pure registration used by Server.init.
  # Do not invoke init callbacks here: future initialization may have effects.
  defp endpoint({path, server}) do
    frame = %Frame{assigns: %{custode_identity: %{kind: :operator, id: "operator"}}}
    frame = if server == Server, do: WorkResources.register(frame), else: frame

    %{
      "path" => path,
      "serverInfo" => server.server_info(),
      "capabilities" => server.server_capabilities(),
      "protocolVersions" => MCPEx.protocol_versions(),
      "tools" => Enum.map(Handlers.get_server_tools(server, frame), &wire/1),
      "resources" => Enum.map(Handlers.get_server_resources(server, frame), &wire/1),
      "resourceTemplates" =>
        Enum.map(Handlers.get_server_resource_templates(server, frame), &wire/1),
      "prompts" => Enum.map(Handlers.get_server_prompts(server, frame), &wire/1)
    }
  end

  # Use the transport's JSON encoder so corrected schemas and optional public
  # fields match discovery; never serialize handlers or validation functions.
  defp wire(component), do: component |> JSON.encode!() |> Jason.decode!()

  defp endpoint_index(endpoints) do
    Enum.map(endpoints, fn endpoint ->
      Enum.reduce(@kinds, endpoint, fn kind, acc ->
        Map.update!(acc, kind, &names/1)
      end)
    end)
  end

  defp names(entries), do: Enum.map(entries, & &1["name"])

  defp merge_definitions(endpoints, kind) do
    endpoints
    |> Enum.flat_map(fn endpoint ->
      Enum.map(endpoint[kind], &{&1["name"], &1, endpoint["path"]})
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, registrations} ->
      definitions = registrations |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      if length(definitions) != 1 do
        raise ArgumentError, "#{kind}: #{name} has different definitions across endpoints"
      end

      entry = %{
        "name" => name,
        "definition" => hd(definitions),
        "endpoints" => registrations |> Enum.map(&elem(&1, 2)) |> Enum.sort()
      }

      if kind == "tools", do: Map.put(entry, "category", category(name)), else: entry
    end)
  end

  defp category(name) do
    case ToolPolicy.fetch(name) do
      {:ok, {:repo_write, verb}} -> "repo_write:#{verb}"
      {:ok, category} -> to_string(category)
      :error -> raise ArgumentError, "tool #{name} has no policy category"
    end
  end

  defp validate_notes!(kind, entries, behavior) do
    names = Enum.map(entries, & &1["name"])
    missing = names -- Map.keys(behavior)
    stale = Map.keys(behavior) -- names

    if missing != [] or stale != [] do
      raise ArgumentError,
            "#{kind} behavior coverage: missing #{inspect(Enum.sort(missing))}; " <>
              "stale #{inspect(Enum.sort(stale))}"
    end

    fields = if kind == "tools", do: ["summary" | @fields], else: @fields

    for name <- names, field <- fields do
      value = behavior[name][field]

      unless is_binary(value) and String.trim(value) != "" do
        raise ArgumentError, "#{kind}.#{name}.#{field} needs a reviewed description"
      end
    end
  end

  @doc "Stable catalog JSON, including order-independent JSON Schema required sets."
  def json(value), do: value |> ordered() |> Jason.encode!(pretty: true)

  defp ordered(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn
      {"required", value} when is_list(value) -> {"required", ordered(Enum.sort(value))}
      {key, value} -> {key, ordered(value)}
    end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp markdown(catalog, overview) do
    IO.iodata_to_binary([
      "# Custode MCP reference\n\n",
      "<!-- Generated by mix custode.mcp.docs. See mcp/README.md before editing. -->\n\n",
      "[Tools](#tools) | [Resources](#resources) | [Resource templates](#resource-templates) | ",
      "[Prompts](#prompts) | [JSON catalog](mcp-reference.json) | [Maintenance](mcp/README.md)\n\n",
      String.trim(overview),
      "\n\n## Registered endpoint inventory\n\n",
      "| Endpoint | Server | Tools | Resources | Templates | Prompts |\n",
      "| --- | --- | ---: | ---: | ---: | ---: |\n",
      Enum.map(catalog["endpoints"], &endpoint_row/1),
      "\n",
      Enum.map(catalog["endpoints"], &endpoint_protocol/1),
      "\n## Tools\n\n",
      "Argument tables preserve discovery types, required flags, descriptions and constraints. ",
      "Read each entry's behavior notes for runtime requirements and defaults. ",
      "The JSON catalog preserves the complete original input schemas and discovery descriptions.\n\n",
      "Categories are descriptive policy metadata, not an authorization guarantee.\n\n",
      "| Tool | Category |\n| --- | --- |\n",
      Enum.map(catalog["tools"], fn entry ->
        "| [#{entry["name"]}](#tool-#{entry["name"]}) | #{entry["category"]} |\n"
      end),
      "\n",
      Enum.map(catalog["tools"], &tool_section/1),
      resource_section("Resources", catalog["resources"]),
      resource_section("Resource templates", catalog["resourceTemplates"]),
      prompt_section(catalog["prompts"])
    ])
  end

  defp endpoint_row(endpoint) do
    counts = Enum.map_join(@kinds, " | ", &to_string(length(endpoint[&1])))
    info = endpoint["serverInfo"]
    "| `#{endpoint["path"]}` | #{info["name"]} #{info["version"]} | #{counts} |\n"
  end

  defp endpoint_protocol(endpoint) do
    versions = Enum.join(endpoint["protocolVersions"], ", ")
    capabilities = endpoint["capabilities"] |> ordered() |> Jason.encode!()

    "**`#{endpoint["path"]}`**: protocol versions #{versions}; capabilities `#{capabilities}`.\n\n"
  end

  defp tool_section(entry) do
    definition = entry["definition"]

    [
      "### Tool: #{entry["name"]}\n\n",
      html(entry["behavior"]["summary"]),
      "\n\n**Endpoints:** #{Enum.join(entry["endpoints"], ", ")}. ",
      "**Category:** #{entry["category"]}.\n\n",
      argument_table(definition["inputSchema"]),
      behavior_section(entry["behavior"]),
      optional_schema("Output schema", definition["outputSchema"])
    ]
  end

  defp argument_table(schema) do
    properties = Map.get(schema, "properties", %{})

    if map_size(properties) == 0 do
      "**Arguments:** none.\n\n"
    else
      [
        "| Argument | Type | Schema required | Description | Other schema constraints |\n",
        "| --- | --- | --- | --- | --- |\n",
        properties |> Enum.sort() |> Enum.map(&argument_row(&1, schema)),
        "\n"
      ]
    end
  end

  defp argument_row({name, property}, schema) do
    required = if name in Map.get(schema, "required", []), do: "yes", else: "no"
    type = Map.get(property, "type", "see constraints")
    constraints = Map.drop(property, ["type", "description"])
    encoded = if constraints == %{}, do: "", else: constraints |> ordered() |> Jason.encode!()

    cells = [name, type, required, property["description"] || "", encoded]
    "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |\n"
  end

  defp cell(value) when is_list(value), do: value |> Enum.join(", ") |> cell()

  defp cell(value) do
    value |> html() |> String.replace("|", "&#124;") |> String.replace("\n", " ")
  end

  defp html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp behavior_section(behavior) do
    Enum.map(@fields, fn field ->
      label =
        %{
          "result" => "Result",
          "effects" => "Side effects",
          "access" => "Access",
          "notes" => "Behavior, defaults and errors"
        }[field]

      "**#{label}:** #{html(behavior[field])}\n\n"
    end)
  end

  defp optional_schema(_label, nil), do: []
  defp optional_schema(label, schema), do: "**#{label}:**\n\n```json\n#{json(schema)}\n```\n\n"

  defp resource_section(title, entries) do
    [
      "## #{title}\n\n",
      Enum.map(entries, fn entry ->
        definition = entry["definition"]
        uri = definition["uri"] || definition["uriTemplate"]

        [
          "### #{entry["name"]}\n\n",
          "`#{uri}`\n\n#{definition["description"]}\n\n",
          "**Endpoints:** #{Enum.join(entry["endpoints"], ", ")}. ",
          "**Media type:** #{definition["mimeType"]}.\n\n",
          behavior_section(entry["behavior"])
        ]
      end)
    ]
  end

  defp prompt_section([]) do
    "## Prompts\n\nNo MCP prompts are currently registered on either endpoint.\n"
  end

  defp prompt_section(entries) do
    [
      "## Prompts\n\n",
      Enum.map(entries, fn entry ->
        [
          "### #{entry["name"]}\n\n#{entry["definition"]["description"]}\n\n",
          "**Endpoints:** #{Enum.join(entry["endpoints"], ", ")}.\n\n",
          optional_schema("Arguments", entry["definition"]["arguments"]),
          behavior_section(entry["behavior"])
        ]
      end)
    ]
  end
end
