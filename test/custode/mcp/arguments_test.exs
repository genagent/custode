defmodule Custode.MCP.ArgumentsTest do
  use ExUnit.Case, async: true

  alias Custode.MCP.{Arguments, NotebookTools, RepoTools, RosterTools, Tools}
  alias Snodo.{Context, Error}
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  test "nested issue drafts retain declared fields without interning caller keys" do
    unknown = "caller_key_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    params = %{
      "repo" => "owner/repo",
      "issues" => [%{"title" => "fix: example", "body" => nil, "labels" => [], unknown => true}],
      "routine_id" => nil,
      unknown => "ignored"
    }

    assert {:ok, %{repo: "owner/repo", issues: [%{title: "fix: example", labels: []}]}} =
             validate(RepoTools.DraftIssues, params)

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "false, zero and empty strings remain values while optional null is absent" do
    assert {:ok, %{id: "example", hermetic: false, max_budget_usd: 0, prompt: ""}} =
             validate(RosterTools.PreviewRoutine, %{
               "id" => "example",
               "hermetic" => false,
               "max_budget_usd" => 0,
               "prompt" => "",
               "model" => nil
             })

    assert {:ok, %{live_only: false}} =
             validate(NotebookTools.JournalRead, %{"live_only" => false})
  end

  test "invalid nested values, required nulls and fractional integer fields are refused" do
    for params <- [
          %{"repo" => nil, "issues" => []},
          %{"repo" => "owner/repo", "issues" => [%{"title" => nil}]},
          %{"repo" => "owner/repo", "issues" => [%{"title" => "fix: example", "labels" => [1]}]},
          %{"repo" => "owner/repo", "issues" => [false]}
        ] do
      assert {:error, %Error{code: -32_602}} = validate(RepoTools.DraftIssues, params)
    end

    for value <- [1.0, 1.5, "1", true] do
      assert {:error, %Error{code: -32_602}} =
               validate(NotebookTools.JournalRead, %{"limit" => value})
    end
  end

  test "native callbacks never infer an operator from missing verified context" do
    context = %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{}
    }

    assert {:error, %Error{code: -32_603, message: "Missing verified Custode identity"}} =
             Tools.ListRoutines.call(%{}, context)
  end

  defp validate(tool, params) do
    schema = tool.input_schema()
    Arguments.validate(params, schema, keys(schema))
  end

  defp keys(schema) do
    own =
      for {name, child} <- Map.get(schema, "properties", %{}), reduce: %{} do
        acc -> acc |> Map.put(name, String.to_existing_atom(name)) |> Map.merge(keys(child))
      end

    Map.merge(own, keys_for_items(schema))
  end

  defp keys_for_items(%{"items" => child}), do: keys(child)
  defp keys_for_items(_schema), do: %{}
end
