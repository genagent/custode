defmodule Custode.MCP.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Custode.Gates.Class
  alias Custode.MCP.ToolPolicy

  doctest Custode.MCP.ToolPolicy

  defp registered do
    ToolPolicy.servers()
    |> Enum.flat_map(& &1.__components__(:tool))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  defp class_verbs do
    Class.ids()
    |> Enum.map(&Class.verbs/1)
    |> Enum.reject(&(&1 == :any))
    |> List.flatten()
    |> Enum.uniq()
  end

  test "every registered tool has a policy entry" do
    missing = Enum.reject(registered(), &match?({:ok, _}, ToolPolicy.fetch(&1)))

    assert missing == [],
           "no Custode.MCP.ToolPolicy entry for: #{Enum.join(missing, ", ")} -- " <>
             "classify each one before it ships"
  end

  test "every policy entry names a registered tool" do
    stale = Map.keys(ToolPolicy.all()) -- registered()
    assert stale == [], "Custode.MCP.ToolPolicy names unregistered tools: #{inspect(stale)}"
  end

  test "every category is a known one" do
    known = [:read, :self_write, :delegate, :peer_message, :roster_write, :operator]

    for {tool, category} <- ToolPolicy.all() do
      assert category in known or match?({:repo_write, verb} when is_atom(verb), category),
             "#{tool} has unknown category #{inspect(category)}"
    end
  end

  test "peer correspondence is distinct from delegated authority and inert reads" do
    for tool <- ~w(peer_send peer_reply peer_ack) do
      assert ToolPolicy.fetch(tool) == {:ok, :peer_message}
    end

    for tool <- ~w(peer_list peer_read) do
      assert ToolPolicy.fetch(tool) == {:ok, :read}
    end
  end

  test "project progress is an inert read, not a delegation grant" do
    assert ToolPolicy.fetch("project_progress") == {:ok, :read}
  end

  test "every repo write verb is in a gate class or listed as in none" do
    for {tool, verb} <- ToolPolicy.repo_writes() do
      assert verb in class_verbs() or verb in ToolPolicy.in_no_class(),
             "#{tool} passes #{inspect(verb)} to the grant check, which no " <>
               "Custode.Gates.Class covers and ToolPolicy.in_no_class/0 does not list"
    end
  end

  test "the in-no-class list is exact" do
    # a verb that gains a class must leave the list, so the list never lies
    assert Enum.filter(ToolPolicy.in_no_class(), &(&1 in class_verbs())) == []
    assert ToolPolicy.in_no_class() -- Map.values(ToolPolicy.repo_writes()) == []
    assert ToolPolicy.in_no_class() == [:mark_issue]
  end

  test "every verb a bounded class names is a repo write tool's verb" do
    assert class_verbs() -- Map.values(ToolPolicy.repo_writes()) == []
  end

  test "each repo write tool's source passes its verb to the grant check" do
    components =
      Enum.flat_map(ToolPolicy.servers(), & &1.__components__(:tool))

    for {tool, verb} <- ToolPolicy.repo_writes() do
      %{handler: module} = Enum.find(components, &(&1.name == tool))
      source = module.module_info(:compile)[:source] |> to_string() |> File.read!()
      [_, body] = String.split(source, "defmodule #{inspect(module)} do", parts: 2)
      body = body |> String.split("\ndefmodule ", parts: 2) |> hd()

      assert body =~ "granted(frame, #{inspect(verb)}," or
               body =~ "check_grant(frame, #{inspect(verb)})",
             "#{tool} does not pass #{inspect(verb)} to granted/3 or check_grant/2"
    end
  end

  test "a specialist's allowlist holds no operator or roster tool" do
    above = for {tool, c} <- ToolPolicy.all(), c in [:operator, :roster_write], do: tool

    granted =
      Enum.map(
        Custode.Routine.mcp_tools(:backlog_worker),
        &String.trim_leading(&1, "mcp__custode__")
      )

    assert Enum.filter(granted, &(&1 in above)) == []
  end
end
