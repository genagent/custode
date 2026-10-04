defmodule Custode.RunContextReceiptsTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Custode.MCP.Identity
  alias Custode.{Repo, ReturnViews, RunContextReceipts}
  alias Snodo.Client
  @human %{kind: :operator, id: "receipt-human"}
  @endpoint CustodeWeb.Endpoint

  setup do
    Repo.delete_all(RunContextReceipts.Row)
    on_exit(fn -> Repo.delete_all(RunContextReceipts.Row) end)
    :ok
  end

  test "both actual adapter inputs retain exact inline layers after source changes and job pruning" do
    for provider <- [:oban_claude, :oban_codex] do
      {job, event} = execution(provider)
      assert {:ok, receipt} = RunContextReceipts.capture(provider, event)
      assert receipt["state"] == "adapter_entered"
      assert receipt["exact_inline_layers"]["prompt"] == "Exact handoff\nOriginal input"
      assert receipt["exact_inline_layers"]["system_prompt"] == "Frozen instructions"
      assert receipt["provider_received"] == "unknown"
      assert receipt["model_used"] == "unknown"
      assert receipt["native_hidden_context"] == "unknown"
      assert receipt["tokens"] == nil
      assert receipt["execution"]["config_revision"] == event.job.meta["config_revision"]
      assert receipt["execution"]["job_id"] == job.id
      assert {:ok, ^receipt} = RunContextReceipts.capture(provider, event)

      assert Repo.aggregate(RunContextReceipts.Row, :count) ==
               if(provider == :oban_claude, do: 1, else: 2)

      Repo.delete!(job)
      assert {:ok, ^receipt} = RunContextReceipts.read(@human, receipt["receipt_id"])

      assert {:ok, %{"receipts" => [summary]}} =
               ReturnViews.invoke(@human, %{
                 "action" => "run_contexts",
                 "agent_id" => event.job.meta["agent_id"]
               })

      refute Map.has_key?(summary, "exact_inline_layers")
    end
  end

  test "queued, stale, mismatched or incomplete execution cannot manufacture context delivery" do
    {job, event} = execution(:oban_claude)

    for invalid <- [
          put_in(event.job.attempt, 2),
          put_in(event.job.meta["agent_generation"], "wrong"),
          put_in(event.args["prompt"], "different"),
          %{event | job: nil}
        ] do
      assert {:error, :unbound_adapter_execution} =
               RunContextReceipts.capture(:oban_claude, invalid)
    end

    Repo.update!(Ecto.Changeset.change(job, state: "available"))
    assert {:error, :unbound_adapter_execution} = RunContextReceipts.capture(:oban_claude, event)
    assert Repo.aggregate(RunContextReceipts.Row, :count) == 0
  end

  test "conflicting same-execution payload cannot overwrite first historical bytes" do
    {job, event} = execution(:oban_claude)
    assert {:ok, first} = RunContextReceipts.capture(:oban_claude, event)
    args = Map.put(job.args, "prompt", "Changed after start")
    Repo.update!(Ecto.Changeset.change(job, args: args))

    assert {:error, :execution_context_conflict} =
             RunContextReceipts.capture(:oban_claude, %{event | args: args})

    assert {:ok, ^first} = RunContextReceipts.read(@human, first["receipt_id"])
  end

  test "same-execution identity drift cannot rebind historical arguments" do
    {job, event} = execution(:oban_claude)
    assert {:ok, first} = RunContextReceipts.capture(:oban_claude, event)
    meta = Map.put(job.meta, "config_revision", "changed-revision")
    Repo.update!(Ecto.Changeset.change(job, meta: meta))

    assert {:error, :execution_context_conflict} =
             RunContextReceipts.capture(:oban_claude, put_in(event.job.meta, meta))

    assert {:ok, ^first} = RunContextReceipts.read(@human, first["receipt_id"])
  end

  test "listing inactive agent physically clears expired inline bytes" do
    {_job, event} = execution(:oban_codex)
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_codex, event)
    row = Repo.get!(RunContextReceipts.Row, receipt["receipt_id"])
    Repo.update!(Ecto.Changeset.change(row, at: DateTime.add(row.at, -8, :day)))

    assert {:ok, [%{"payload_state" => "expired"}]} =
             RunContextReceipts.list(@human, row.agent_id)

    assert Repo.get!(RunContextReceipts.Row, row.receipt_id).payload == nil
  end

  test "operator-only historical context reads refuse agent and missing identities" do
    {_job, event} = execution(:oban_claude)
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_claude, event)

    for actor <- [
          nil,
          %{kind: :operator, id: ""},
          %{kind: :routine, id: event.job.meta["agent_id"]},
          %{kind: :sub_agent, id: "helper"}
        ] do
      assert {:error, "operator_required"} =
               ReturnViews.invoke(actor, %{
                 "action" => "run_context",
                 "receipt_id" => receipt["receipt_id"]
               })

      assert {:error, "operator_required"} =
               ReturnViews.invoke(actor, %{
                 "action" => "run_contexts",
                 "agent_id" => event.job.meta["agent_id"]
               })
    end
  end

  test "file-based and hidden instructions remain unknown; expired and oversized payload never use current files" do
    {job, event} = execution(:oban_claude)
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_claude, event)
    assert Enum.all?(receipt["file_layers"], &(&1["content_state"] == "not_observed"))
    row = Repo.get!(RunContextReceipts.Row, receipt["receipt_id"])
    Repo.update!(Ecto.Changeset.change(row, at: DateTime.add(row.at, -8, :day)))
    assert {:ok, expired} = RunContextReceipts.read(@human, receipt["receipt_id"])
    assert expired["payload_state"] == "expired"
    assert expired["exact_inline_layers"] == nil
    assert Repo.get!(RunContextReceipts.Row, row.receipt_id).payload == nil
    args = Map.put(job.args, "prompt", String.duplicate("x", 140_000))
    Repo.update!(Ecto.Changeset.change(job, attempt: 2, args: args))

    assert {:ok, oversized} =
             RunContextReceipts.capture(:oban_claude, %{
               event
               | args: args,
                 job: %{event.job | attempt: 2}
             })

    assert oversized["payload_state"] == "over_budget"
    assert oversized["exact_inline_layers"] == nil
    assert oversized["layers"] |> hd() |> Map.fetch!("bytes") == 140_000
  end

  test "read-only detail folds retained context and never substitutes another agent's receipt" do
    {_job, event} = execution(:oban_claude)
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_claude, event)
    agent = event.job.meta["agent_id"]
    path = "/contexts/" <> agent <> "?receipt=" <> receipt["receipt_id"]
    assert {:ok, view, html} = live(build_conn(), path)
    assert html =~ "Frozen instructions"
    assert has_element?(view, "details#run-context-inline:not([open])")
    assert has_element?(view, "details#run-context-execution:not([open])")
    assert html =~ "Provider receipt"

    assert {:ok, _view, other} =
             live(build_conn(), "/contexts/other-agent?receipt=" <> receipt["receipt_id"])

    refute other =~ "Frozen instructions"
    assert other =~ "not in this agent"
  end

  test "scheduled execution with no correlation and retries remain distinct" do
    {job, event} = execution(:oban_claude)
    meta = Map.delete(event.job.meta, "correlation_id")
    Repo.update!(Ecto.Changeset.change(job, meta: meta))
    event = put_in(event.job.meta, meta)
    assert {:ok, first} = RunContextReceipts.capture(:oban_claude, event)
    Repo.update!(Ecto.Changeset.change(job, meta: meta, attempt: 2))
    assert {:ok, second} = RunContextReceipts.capture(:oban_claude, put_in(event.job.attempt, 2))
    refute first["receipt_id"] == second["receipt_id"]
  end

  test "Codex inline developer instructions are retained without credential-bearing overrides" do
    {job, event} = execution(:oban_codex)

    args =
      Map.put(job.args, "config_overrides", [
        "developer_instructions=" <> Jason.encode!("Exact Codex\nInstructions"),
        "model_reasoning_effort=\"high\"",
        "mcp_servers.custode.http_headers.Authorization=\"Bearer secret-fixture-token\""
      ])

    Repo.update!(Ecto.Changeset.change(job, args: args))
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_codex, %{event | args: args})
    assert receipt["exact_inline_layers"]["developer_instructions"] == "Exact Codex\nInstructions"
    refute Jason.encode!(receipt) =~ "secret-fixture-token"
    refute Jason.encode!(receipt) =~ "http_headers"
  end

  test "released wrapper telemetry observes the exact admitted arguments without a provider call" do
    {job, event} = execution(:oban_claude)

    query = fn prompt, _options ->
      assert prompt == event.args["prompt"]
      {:error, :synthetic_nonpaid_stop}
    end

    ObanClaude.run(event.args, job: job, query_fun: query)
    assert {:ok, [receipt]} = RunContextReceipts.list(@human, job.meta["agent_id"])
    assert receipt["state"] == "adapter_entered"
  end

  test "retention retires payload beyond the newest hundred while preserving metadata" do
    {job, event} = execution(:oban_claude)

    receipts =
      for attempt <- 1..101 do
        Repo.update!(Ecto.Changeset.change(job, attempt: attempt))

        assert {:ok, receipt} =
                 RunContextReceipts.capture(:oban_claude, put_in(event.job.attempt, attempt))

        receipt
      end

    assert {:ok, oldest} = RunContextReceipts.read(@human, hd(receipts)["receipt_id"])
    assert oldest["payload_state"] == "retired"
    assert oldest["exact_inline_layers"] == nil
    assert oldest["layers"] != []
    assert {:ok, recent} = RunContextReceipts.list(@human, job.meta["agent_id"])
    assert length(recent) == 100
    assert Repo.aggregate(RunContextReceipts.Row, :count) == 101
  end

  test "both real MCP dialects use the same operator context receipt operation" do
    {_job, event} = execution(:oban_claude)
    assert {:ok, receipt} = RunContextReceipts.capture(:oban_claude, event)
    token = Identity.mint(:operator, @human.id)
    url = Custode.MCP.url()

    for version <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, url},
                 protocol: version,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               Client.call_tool(client, "return_context", %{
                 "action" => "run_context",
                 "receipt_id" => receipt["receipt_id"]
               })

      assert Jason.decode!(text)["exact_inline_layers"]["prompt"] == event.args["prompt"]
      assert :ok = Client.close(client)
    end
  end

  defp execution(provider) do
    meta =
      Map.new(
        ~w(agent_id agent_generation agent_turn_id arc_id config_revision correlation_id),
        &{&1, uid(&1)}
      )

    args = %{
      "prompt" => "Exact handoff\nOriginal input",
      "system_prompt" => "Frozen instructions",
      "model" => "synthetic-fixture",
      "effort" => "low",
      "system_prompt_file" => "/missing/never-read"
    }

    worker = if provider == :oban_claude, do: "ObanClaude.Agent.Job", else: "ObanCodex.Agent.Job"

    job =
      Repo.insert!(%Oban.Job{
        worker: worker,
        queue: "agents",
        state: "executing",
        attempt: 1,
        args: args,
        meta: meta
      })

    on_exit({:context_job, job.id}, fn ->
      Repo.delete_all(from(stored in Oban.Job, where: stored.id == ^job.id))
    end)

    {job, %{args: args, job: %{id: job.id, attempt: 1, meta: meta}}}
  end
end
