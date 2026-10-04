defmodule Custode.ReadCompositionsTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.MCP.{Capabilities, Identity}
  alias Custode.ReadCompositions
  alias Custode.ReadCompositions.Row
  alias Custode.Repo
  alias Custode.Repository
  alias Snodo.Client
  @human %{kind: :operator, id: "composition-human"}

  defmodule Ops do
    def view_pr(_owner, _repo, number),
      do: result("repo_view_pr", %{number: number, head_sha: "old"})

    def pr_checks(_owner, _repo, _number), do: result("repo_pr_checks", %{sha: "new", checks: []})

    def pr_diff(_owner, _repo, _number),
      do: result("repo_pr_diff", %{files: [%{filename: "a", patch: "diff"}]})

    defp result(tool, value) do
      send(Application.fetch_env!(:custode, :composition_test_pid), {:read, tool})
      if callback = Application.get_env(:custode, :composition_read_callback), do: callback.(tool)

      Application.get_env(:custode, :composition_result_overrides, %{})
      |> Map.get(tool, {:ok, value})
    end
  end

  defmodule OtherOps do
    def marker, do: :different
  end

  setup do
    owner = routine_fixture!(tmp_workspace!(), %{repo: "acme/" <> uid("composition")})
    put_env!(:read_composition_owner, owner.id)
    put_env!(:repo_ops, Ops)
    put_env!(:composition_test_pid, self())
    put_env!(:composition_read_callback, nil)
    put_env!(:composition_result_overrides, %{})
    Repository.ensure_served(owner.repo, owner.id)
    on_exit(fn -> Repo.delete_all(Row) end)

    %{
      owner: owner,
      actor: %{kind: :routine, id: owner.id},
      args: %{"repo" => owner.repo, "number" => 9}
    }
  end

  test "publication is inert and activation is human-only, first-winner and ABA safe", ctx do
    assert {:ok, definition} =
             ReadCompositions.publish(@human, ReadCompositions.template(ctx.owner.repo))

    assert {:ok, %{"entries" => []}} = ReadCompositions.list(ctx.actor)

    assert {:error, _reason} =
             ReadCompositions.publish(ctx.actor, ReadCompositions.template(ctx.owner.repo))

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          ReadCompositions.activate(@human, "pr_review_context", definition["revision"], 0)
        end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :activation_conflict} in results

    assert {:ok, %{"generation" => 2}} =
             ReadCompositions.activate(@human, "pr_review_context", nil, 1)

    assert {:ok, %{"entries" => [], "activation" => %{"generation" => 2, "revision" => nil}}} =
             ReadCompositions.list(@human)

    assert {:ok, worker_list} = ReadCompositions.list(ctx.actor)
    refute Map.has_key?(worker_list, "activation")

    assert {:ok, %{"generation" => 3}} =
             ReadCompositions.activate(@human, "pr_review_context", definition["revision"], 2)

    assert {:error, :activation_conflict} =
             ReadCompositions.activate(@human, "pr_review_context", nil, 1)
  end

  test "JSON refs have no evaluation path and invalid or excessive definitions are refused",
       ctx do
    source = ReadCompositions.template(ctx.owner.repo)

    for invalid <- [
          Map.put(source, "module", "System"),
          Map.put(source, "steps", ["shell"]),
          put_in(source, ["steps", Access.at(0), "arguments", "number"], "$(touch nope)"),
          Map.put(source, "steps", List.duplicate(hd(source["steps"]), 4))
        ] do
      assert {:error, :invalid_definition} = ReadCompositions.publish(@human, invalid)
    end

    assert {:error, :invalid_composition_request} =
             ReadCompositions.call(
               @human,
               %{"action" => "list", "actor" => "forged"}
             )

    assert Repo.aggregate(Row, :count) == 0
  end

  test "successful reads retain exact caller trace and disclose mixed revision limits", ctx do
    activate!(ctx)
    assert {:ok, result} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
    assert result["status"] == "complete"
    assert map_size(result["results"]) == 3
    assert result["coherence"] =~ "diff_has_no_head_binding"
    assert {:ok, trace} = ReadCompositions.trace(ctx.actor, result["trace_id"])
    assert trace["actor"] == %{"kind" => "routine", "id" => ctx.owner.id}
    assert length(trace["steps"]) == 3
    refute Map.has_key?(trace, "results")
    refute Map.has_key?(trace, "arguments")

    assert {:error, :invalid_arguments} =
             ReadCompositions.invoke(
               ctx.actor,
               "pr_review_context",
               Map.put(ctx.args, "actor", "operator")
             )

    assert {:error, :invalid_arguments} =
             ReadCompositions.invoke(
               ctx.actor,
               "pr_review_context",
               Map.put(ctx.args, "repo", "outside/repo")
             )
  end

  test "other owners/helpers cannot discover or invoke; grant withdrawal stops next read", ctx do
    activate!(ctx)

    for actor <- [%{kind: :routine, id: "another"}, %{kind: :sub_agent, id: ctx.owner.id}, %{}] do
      assert {:error, _reason} = ReadCompositions.list(actor)
      assert {:error, _reason} = ReadCompositions.invoke(actor, "pr_review_context", ctx.args)
      refute "read_composition" in Capabilities.authorized_tool_names(:main, actor)
    end

    put_env!(:composition_read_callback, fn
      "repo_view_pr" -> Application.put_env(:custode, :read_composition_owner, "withdrawn")
      _tool -> :ok
    end)

    assert {:ok, result} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
    assert map_size(result["results"]) == 1
    assert result["status"] == "authorization_activation_or_dependency_changed"
    assert_receive {:read, "repo_view_pr"}
    refute_receive {:read, "repo_pr_checks"}
  end

  test "replacement, disable and dependency changes stop in-flight calls with partial results",
       ctx do
    definition = activate!(ctx)

    for change <- [:disable, :rollback, :dependency] do
      put_env!(:repo_ops, Ops)
      activation = Repo.get!(Row, "activation:pr_review_context").data

      if activation["revision"] == nil do
        ReadCompositions.activate(
          @human,
          "pr_review_context",
          definition["revision"],
          activation["generation"]
        )
      end

      put_env!(:composition_read_callback, fn
        "repo_view_pr" -> change!(change, definition)
        _tool -> :ok
      end)

      assert {:ok, result} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
      assert map_size(result["results"]) == 1
      assert result["status"] == "authorization_activation_or_dependency_changed"
    end
  end

  test "partial read errors and schema/byte limits never replace earlier results", ctx do
    activate!(ctx)

    for {override, reason} <- [
          {{:error, "private upstream text"}, "dependency_read_failed"},
          {{:ok, %{checks: []}}, "invalid_dependency_result"},
          {{:ok, %{sha: "x", checks: [%{text: String.duplicate("x", 70_000)}]}}, "output_limit"},
          {{:ok, %{sha: "x", checks: List.duplicate(%{}, 101)}}, "invalid_dependency_result"}
        ] do
      put_env!(:composition_result_overrides, %{"repo_pr_checks" => override})
      assert {:ok, result} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
      assert map_size(result["results"]) == 1
      assert result["status"] == reason
    end
  end

  test "bounded retained traces and reconstruction preserve activation", ctx do
    activate!(ctx)
    for _ <- 1..102, do: ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
    assert Repo.aggregate(from(r in Row, where: r.kind == "trace"), :count) == 100
    assert {:ok, %{"entries" => [entry]}} = ReadCompositions.list(ctx.actor)
    assert entry["generation"] == 1
    assert Repo.get!(Row, "definition:" <> entry["revision"]).kind == "definition"
  end

  test "new immutable versions replace and roll back after the SQLite process restarts", ctx do
    first = activate!(ctx)

    source =
      ReadCompositions.template(ctx.owner.repo)
      |> Map.put("description", "Changed read presentation.")

    assert {:ok, second} = ReadCompositions.publish(@human, source)
    refute first["revision"] == second["revision"]

    assert {:ok, _pointer} =
             ReadCompositions.activate(@human, "pr_review_context", second["revision"], 1)

    assert {:ok, result} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
    assert result["revision"] == second["revision"]
    assert :ok = Supervisor.terminate_child(Custode.Supervisor, Repo)
    assert {:ok, _pid} = Supervisor.restart_child(Custode.Supervisor, Repo)
    assert {:ok, retained} = ReadCompositions.trace(ctx.actor, result["trace_id"])
    assert retained["revision"] == second["revision"]

    assert {:ok, %{"generation" => 3}} =
             ReadCompositions.activate(@human, "pr_review_context", first["revision"], 2)

    assert {:ok, rolled_back} = ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)
    assert rolled_back["revision"] == first["revision"]
    assert Repo.get!(Row, "definition:" <> second["revision"]).data == second
  end

  test "discovery withholds definitions whose compiled dependency changed", ctx do
    activate!(ctx)
    put_env!(:repo_ops, OtherOps)
    assert {:ok, %{"entries" => []}} = ReadCompositions.list(ctx.actor)
  end

  test "unconfirmed invocations retain uncertainty and never dispatch past capacity", ctx do
    activate!(ctx)

    for n <- 1..10 do
      Repo.insert!(%Row{
        id: "trace:pending-#{n}",
        kind: "trace",
        name: "pr_review_context",
        data: %{"status" => "pending"}
      })
    end

    assert {:error, :unconfirmed_invocation_capacity} =
             ReadCompositions.invoke(ctx.actor, "pr_review_context", ctx.args)

    refute_receive {:read, _tool}
  end

  test "real Snodo discovery, invocation, disable and rollback on both protocol revisions", ctx do
    definition = activate!(ctx)
    token = Identity.mint(:routine, ctx.owner.id)

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1["name"] == "read_composition"))
      refute Enum.any?(tools, &(&1["name"] == "read_composition_configure"))

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               Client.call_tool(client, "read_composition", %{
                 "request" => %{
                   "action" => "invoke",
                   "name" => "pr_review_context",
                   "arguments" => ctx.args
                 }
               })

      assert Jason.decode!(text)["status"] == "complete"
      current = Repo.get!(Row, "activation:pr_review_context").data

      assert {:ok, disabled} =
               ReadCompositions.activate(@human, "pr_review_context", nil, current["generation"])

      assert {:ok, %{"isError" => true}} =
               Client.call_tool(client, "read_composition", %{
                 "request" => %{
                   "action" => "invoke",
                   "name" => "pr_review_context",
                   "arguments" => ctx.args
                 }
               })

      assert {:ok, _active} =
               ReadCompositions.activate(
                 @human,
                 "pr_review_context",
                 definition["revision"],
                 disabled["generation"]
               )

      assert :ok = Client.close(client)
    end

    {:ok, human_token} = Identity.operator_token()

    assert {:ok, client} =
             Client.connect({:http, Custode.MCP.url()},
               headers: [{"authorization", "Bearer " <> human_token}]
             )

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(client, "read_composition_configure", %{
               "request" => %{
                 "action" => "publish",
                 "definition" => ReadCompositions.template(ctx.owner.repo)
               }
             })

    assert Jason.decode!(text)["revision"] == definition["revision"]
    Client.close(client)
  end

  defp change!(:dependency, _definition), do: Application.put_env(:custode, :repo_ops, OtherOps)

  defp change!(action, definition) do
    current = Repo.get!(Row, "activation:pr_review_context").data

    {:ok, disabled} =
      ReadCompositions.activate(@human, "pr_review_context", nil, current["generation"])

    if action == :rollback do
      ReadCompositions.activate(
        @human,
        "pr_review_context",
        definition["revision"],
        disabled["generation"]
      )
    end
  end

  defp activate!(ctx) do
    {:ok, definition} =
      ReadCompositions.publish(@human, ReadCompositions.template(ctx.owner.repo))

    {:ok, _active} =
      ReadCompositions.activate(@human, "pr_review_context", definition["revision"], 0)

    definition
  end
end
