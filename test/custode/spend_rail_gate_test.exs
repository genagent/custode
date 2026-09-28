defmodule Custode.SpendRailGateTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Agents
  alias Custode.Gates
  alias Custode.MCP.OperatorTools
  alias Custode.SpendLedger

  @endpoint CustodeWeb.Endpoint
  @frame %Anubis.Server.Frame{}

  setup do
    clear_attention!()

    path = Path.join(System.tmp_dir!(), uid("rail-gate") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    %{conn: build_conn()}
  end

  for provider <- [:claude, :codex] do
    test "#{provider} preserves a permission gate when the same turn trips its rail", %{
      conn: conn
    } do
      provider = unquote(provider)
      routine = start_budgeted_routine!(provider)
      {result, turn_meta} = run_over_rail!(routine, provider)

      # Spend telemetry runs before the provider worker delivers the result.
      # The rail must be armed here without pre-empting that result.
      assert SpendLedger.today_tokens(routine.id) == 1_300
      assert {:ok, :running} = Agents.status(routine.id)

      assert :ok = Agents.cast_prompt(routine.id, "do not start under the tripped rail")
      refute_receive {:enqueued, _, _}

      assert :ok = finish(provider, turn_meta, result)

      assert {:ok, {:awaiting_permission, %{id: action_id}}} =
               Agents.await(routine.id, :awaiting_permission, 1_000)

      gate =
        eventually(fn ->
          assert [%{action_id: ^action_id, detail: "publish the release"} = gate] =
                   Gates.open_gates(routine.id)

          gate
        end)

      listed = tool_json(OperatorTools.ListGates.execute(%{status: "open"}, @frame))

      assert %{
               "action_id" => ^action_id,
               "detail" => "publish the release",
               "status" => "open"
             } = Enum.find(listed["gates"], &(&1["agent_id"] == routine.id))

      {:ok, view, html} = live(conn, "/console/#{routine.id}")
      assert html =~ "publish the release"
      assert html =~ "needs approval"
      assert has_element?(view, "#subject-rail", routine.id)

      assert :rejected = Agents.reject_action(routine.id, action_id, "not today")
      assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)
      refute_receive {:enqueued, _, _}, 100

      eventually(fn ->
        assert %{status: "resolved", outcome: "rejected"} =
                 Custode.Repo.get!(Gates.Gate, gate.id)

        assert [entry] =
                 Custode.Feed.for_agent(routine.id)
                 |> Enum.filter(&(&1["event"] == "budget_paused"))

        assert entry["action"] =~ "daily token rail hit"
      end)
    end
  end

  test "rail enforcement targets the provider that owns the turn after a roster edit" do
    routine = start_budgeted_routine!(:claude)
    assert :processing = ObanClaude.Agent.submit_prompt(routine.id, "finish on claude")

    assert_receive {:enqueued, %{"prompt" => "finish on claude"}, turn_meta}

    # The next-roster provider changed while this turn was live. Telemetry
    # still names the provider that owns the captured generation and turn.
    put_env!(:routines, [
      %{
        id: routine.id,
        provider: :codex,
        cron: :manual,
        workspace: routine.workspace,
        working_dir: routine.working_dir,
        prompt: routine.prompt,
        daily_budget_usd: nil,
        daily_budget_tokens: 1_000
      }
    ])

    result =
      structured_result(:claude, %{
        "directive" => "request_permission",
        "action" => "publish from the original provider",
        "action_class" => "release"
      })

    assert {:ok, ^result} =
             ObanClaude.run(%{"prompt" => "finish on claude"},
               job: job(turn_meta),
               query_fun: ObanClaude.Testing.respond(result)
             )

    assert {:ok, %{deferred_pause: %{reason: reason}}} =
             ObanClaude.Agent.info(routine.id)

    assert reason =~ "daily token rail hit"
    assert {:ok, :offline} = ObanCodex.Agent.status(routine.id)

    assert :ok = finish(:claude, turn_meta, result)

    assert {:ok, {:awaiting_permission, %{id: action_id}}} =
             ObanClaude.Agent.await(routine.id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert [%{action_id: ^action_id, detail: "publish from the original provider"}] =
               Gates.open_gates(routine.id)

      assert Enum.any?(
               Custode.Feed.for_agent(routine.id),
               &(&1["event"] == "needs_approval" and
                   &1["action"] == "publish from the original provider")
             )
    end)

    assert :rejected = ObanClaude.Agent.reject_action(routine.id, action_id, "not today")
    assert {:ok, :paused} = ObanClaude.Agent.await(routine.id, :paused, 1_000)
  end

  defp start_budgeted_routine!(provider) do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: provider,
        cron: :manual,
        daily_budget_usd: nil,
        daily_budget_tokens: 1_000
      })

    test_pid = self()

    {:ok, _pid} =
      Agents.start_agent(routine.id,
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agents.stop_agent(routine.id, provider) end)
    routine
  end

  defp run_over_rail!(routine, provider) do
    assert :processing = Agents.submit_prompt(routine.id, "prepare release")

    assert_receive {:enqueued, %{"prompt" => "prepare release"}, %{"agent_id" => id} = turn_meta}

    assert id == routine.id

    result =
      structured_result(provider, %{
        "directive" => "request_permission",
        "action" => "publish the release",
        "action_class" => "release"
      })

    job = job(turn_meta)

    case provider do
      :claude ->
        assert {:ok, ^result} =
                 ObanClaude.run(%{"prompt" => "prepare release"},
                   job: job,
                   query_fun: ObanClaude.Testing.respond(result)
                 )

      :codex ->
        assert {:ok, ^result} =
                 ObanCodex.run(%{"prompt" => "prepare release"},
                   job: job,
                   query_fun: ObanCodex.Testing.respond(result)
                 )
    end

    {result, turn_meta}
  end

  defp structured_result(:claude, data) do
    ObanClaude.Testing.structured_result(data,
      extra: %{
        "usage" => %{
          "input_tokens" => 900,
          "output_tokens" => 400,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0
        }
      }
    )
  end

  defp structured_result(:codex, data) do
    ObanCodex.Testing.structured_result(data,
      usage: %{
        "input_tokens" => 900,
        "output_tokens" => 400,
        "cached_input_tokens" => 0
      }
    )
  end

  defp finish(:claude, turn_meta, result) do
    ObanClaude.Agent.Job.handle_result(result, job(turn_meta))
  end

  defp finish(:codex, turn_meta, result) do
    ObanCodex.Agent.Job.handle_result(result, job(turn_meta))
  end

  defp job(meta),
    do: %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: 1,
      max_attempts: 1,
      meta: meta
    }
end
