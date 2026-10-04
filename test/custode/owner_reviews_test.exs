defmodule Custode.OwnerReviewsTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Custode.MCP.{Capabilities, ToolPolicy}
  alias Custode.{OwnerReviewJob, OwnerReviews, Repo}
  @human %{kind: :operator, id: "review-test"}

  setup do
    owner =
      routine_fixture!(tmp_workspace!(), %{
        model: "sonnet",
        max_budget_usd: 2.0,
        timeout_ms: 60_000,
        daily_budget_usd: 5.0
      })

    request = %{
      "request_id" => uid("review"),
      "owner_id" => owner.id,
      "evidence" => "Frozen PR diff and failing test evidence.",
      "routes" => [
        %{"provider" => "claude", "model" => "sonnet", "effort" => "medium"},
        %{"provider" => "claude", "model" => "opus", "effort" => "high"}
      ],
      "limits" => %{"calls" => 2, "usd" => 1.0, "time_ms" => 30_000}
    }

    on_exit(fn -> Repo.delete_all(OwnerReviews.Row) end)
    %{owner: owner, request: request}
  end

  test "atomic two-job submission, captured evidence and idempotent concurrent retry", ctx do
    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> OwnerReviews.submit(@human, ctx.request) end) end)
      |> Enum.map(&Task.await/1)

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second
    assert length(first["children"]) == 2
    assert first["request"]["evidence"] == ctx.request["evidence"]
    assert first["acceptance"] == "owner_required"
    assert first["token_cap"] == "unsupported"
    assert first["parent_execution"]["desired"]["config_revision"] == first["owner_revision"]

    assert {:error, :idempotency_conflict} =
             OwnerReviews.submit(@human, %{ctx.request | "evidence" => "different"})

    assert {:ok, same} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert same == first
  end

  test "owner scope is enforced across submit, inspect and cancel", ctx do
    assert {:ok, _run} = OwnerReviews.submit(%{kind: :routine, id: ctx.owner.id}, ctx.request)

    for actor <- [%{kind: :routine, id: "another"}, %{kind: :sub_agent, id: ctx.owner.id}, %{}] do
      assert {:error, :owner_scope_unavailable} = OwnerReviews.submit(actor, ctx.request)

      assert {:error, :owner_scope_unavailable} =
               OwnerReviews.read(actor, ctx.request["request_id"])

      assert {:error, :owner_scope_unavailable} =
               OwnerReviews.cancel(actor, ctx.request["request_id"])
    end
  end

  test "unsupported hard token caps, providers and excessive limits never enqueue", ctx do
    assert {:error, :hard_token_cap_unavailable} =
             OwnerReviews.submit(
               @human,
               put_in(ctx.request, ["limits", "tokens"], 1000)
             )

    assert {:error, :unsupported_route} =
             OwnerReviews.submit(
               @human,
               put_in(ctx.request, ["routes"], [
                 %{"provider" => "codex", "model" => "sol", "effort" => "high"},
                 hd(ctx.request["routes"])
               ])
             )

    assert {:error, :above_owner_limits} =
             OwnerReviews.submit(
               @human,
               put_in(ctx.request, ["limits", "usd"], 3.0)
             )

    assert Repo.get(OwnerReviews.Row, ctx.request["request_id"]) == nil
  end

  test "aggregate daily review reservations serialize and retain unknown cost", ctx do
    put_env!(:routines, [Map.put(ctx.owner, :daily_budget_usd, 1.5)])
    assert {:ok, _run} = OwnerReviews.submit(@human, ctx.request)

    assert {:error, :daily_usd_capacity} =
             OwnerReviews.submit(
               @human,
               %{ctx.request | "request_id" => uid("second-review")}
             )

    assert {:ok, _cancel} = OwnerReviews.cancel(@human, ctx.request["request_id"])

    assert {:error, :daily_usd_capacity} =
             OwnerReviews.submit(
               @human,
               %{ctx.request | "request_id" => uid("third-review")}
             )
  end

  test "parallel callbacks preserve partial failure, unknown usage and first result", ctx do
    pid = self()

    put_env!(:owner_review_query_fun, fn prompt, opts ->
      argv =
        ClaudeWrapper.Query.new(prompt)
        |> ClaudeWrapper.Query.apply_opts(opts)
        |> ClaudeWrapper.Query.build_args()

      send(pid, {:native_options, opts, argv})

      if opts[:model] == "sonnet" do
        {:ok, %ClaudeWrapper.Result{extra: %{"structured_output" => answer()}}}
      else
        {:error, ClaudeWrapper.Error.new(:command_failed)}
      end
    end)

    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    jobs = Enum.map(run["children"], &Repo.get!(Oban.Job, &1["job_id"]))

    returns =
      jobs
      |> Enum.map(fn job -> Task.async(fn -> OwnerReviewJob.perform(job) end) end)
      |> Enum.map(&Task.await/1)

    assert :ok in returns
    assert {:cancel, :review_failed} in returns

    for _ <- 1..2 do
      assert_receive {:native_options, opts, argv}
      assert opts[:tools] == [""]
      assert opts[:mcp_config] == []
      assert opts[:hermetic] == :full
      assert opts[:max_turns] == 1
      assert opts[:max_budget_usd] == 0.5
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--tools", ""])
      assert "--strict-mcp-config" in argv
      refute "--bare" in argv
      assert "--disable-slash-commands" in argv
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--setting-sources", ""])
    end

    assert {:ok, after_run} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert after_run["status"] == "partial"
    assert hd(after_run["children"])["usage"] == %{"usd" => nil, "tokens" => nil}
    [first | _] = jobs

    assert {:ok, _ignored} =
             OwnerReviews.complete(
               first,
               "completed",
               %{"summary" => "late changed"},
               nil,
               "fake"
             )

    assert {:ok, same} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert same == after_run
    stale = %{first | args: Map.put(first.args, "review_attempt", "wrong")}

    assert {:error, :stale_attempt} =
             OwnerReviews.complete(stale, "completed", answer(), nil, "fake")

    refute Map.has_key?(same, "approved")
  end

  test "cancellation before launch never invokes provider and remains separate from settlement",
       ctx do
    put_env!(:owner_review_query_fun, fn _, _ -> flunk("cancelled review launched") end)
    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    assert {:ok, cancelled} = OwnerReviews.cancel(@human, ctx.request["request_id"])
    assert cancelled["status"] == "cancel_requested"

    for child <- run["children"] do
      job = Repo.get!(Oban.Job, child["job_id"])
      assert {:cancel, :cancel_requested} = OwnerReviewJob.perform(job)
    end

    assert {:ok, final} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert Enum.all?(final["children"], &(&1["settlement"] == "not_launched"))
    assert {:ok, same} = OwnerReviews.cancel(@human, ctx.request["request_id"])
    assert same == final
  end

  test "crashed job without completion projects uncertainty; no read launches recovery", ctx do
    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    first = hd(run["children"])
    job = Repo.get!(Oban.Job, first["job_id"])
    assert {:ok, _record} = OwnerReviews.start(job)
    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    assert {:ok, projected} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert hd(projected["children"])["status"] == "unconfirmed"
    assert hd(projected["children"])["settlement"] == "unknown"
    assert {:ok, _same} = OwnerReviews.submit(@human, ctx.request)

    assert Repo.get!(OwnerReviews.Row, ctx.request["request_id"]).record["children"] |> length() ==
             2
  end

  test "deadline, changed owner and exhausted rail stop child admission", ctx do
    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    job = Repo.get!(Oban.Job, hd(run["children"])["job_id"])
    row = Repo.get!(OwnerReviews.Row, ctx.request["request_id"])
    row |> Ecto.Changeset.change(record: Map.put(row.record, "deadline_ms", 0)) |> Repo.update!()
    assert {:cancel, :deadline} = OwnerReviewJob.perform(job)
    put_env!(:routines, [Map.put(ctx.owner, :model, "opus")])

    assert {:error, :owner_changed} =
             OwnerReviews.start(Repo.get!(Oban.Job, List.last(run["children"])["job_id"]))
  end

  test "duplicate execution cannot overwrite a live review; cancellation retains its later result",
       ctx do
    pid = self()

    put_env!(:owner_review_query_fun, fn _, _ ->
      send(pid, {:review_running, self()})

      receive do
        :finish -> {:ok, %ClaudeWrapper.Result{extra: %{"structured_output" => answer()}}}
      end
    end)

    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    job = Repo.get!(Oban.Job, hd(run["children"])["job_id"])
    task = Task.async(fn -> OwnerReviewJob.perform(job) end)
    assert_receive {:review_running, child_pid}
    assert {:cancel, :already_started} = OwnerReviewJob.perform(job)
    assert {:ok, pending} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert hd(pending["children"])["status"] == "running"
    job |> Ecto.Changeset.change(state: "executing") |> Repo.update!()
    assert {:ok, cancellation} = OwnerReviews.cancel(@human, ctx.request["request_id"])
    assert cancellation["cancel_requested"]
    assert hd(cancellation["children"])["settlement"] == "unknown"
    send(child_pid, :finish)
    assert :ok = Task.await(task)
    assert {:ok, result} = OwnerReviews.read(@human, ctx.request["request_id"])
    assert result["status"] == "cancel_requested"
    assert hd(result["children"])["result"] == answer()
  end

  test "MCP uses the same scoped operation and requires explicit identity", ctx do
    alias Custode.MCP.{CallContext, OwnerReviewTools}
    frame = %CallContext{assigns: %{custode_identity: @human}}
    params = %{action: "submit", request: ctx.request}
    assert %{"request" => request} = tool_json(OwnerReviewTools.Review.execute(params, frame))
    assert request == ctx.request

    assert tool_error(OwnerReviewTools.Review.execute(params, %CallContext{})) =~
             "unauthenticated"

    assert ToolPolicy.fetch("owner_review") == {:ok, :delegate}

    refute "mcp__custode__owner_review" in Capabilities.authorized_tool_names(
             :memory,
             %{kind: :sub_agent, id: "helper"}
           )
  end

  test "known usage is recorded once in the existing ledger without inventing an Attempt", ctx do
    assert {:ok, run} = OwnerReviews.submit(@human, ctx.request)
    job = Repo.get!(Oban.Job, hd(run["children"])["job_id"])
    assert {:ok, _started} = OwnerReviews.start(job)
    usage = %{"usd" => 0.2, "tokens" => %{input: 10, output: 5}}

    assert {:ok, _result} =
             OwnerReviews.complete(job, "completed", answer(), usage, "query_returned")

    assert {:ok, _same} =
             OwnerReviews.complete(job, "completed", answer(), usage, "query_returned")

    assert Custode.SpendLedger.today(ctx.owner.id) == 0.2
    assert Custode.SpendLedger.today_tokens(ctx.owner.id) == 15
  end

  defp answer,
    do: %{
      "verdict" => "findings",
      "summary" => "Seeded defect found.",
      "findings" => [
        %{"severity" => "high", "reference" => "diff:line-4", "description" => "Missing guard."}
      ],
      "uncertainty" => "No independent reproduction performed."
    }
end
