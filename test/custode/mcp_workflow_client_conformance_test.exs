defmodule Custode.MCPWorkflowClientConformanceTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, Feed, OperatorMessage, PeerMessage, Repo, Workflow}
  alias Custode.MCP.Identity
  alias Custode.Workflow.{Launch, Node, Results, Run, Stage}

  @moduletag timeout: 120_000

  setup do
    name = uid("conformance-workflow")
    repo = uid("conformance-repo")
    caretaker = uid("conformance-caretaker")

    put_env!(:extra_workflows, %{
      name =>
        Workflow.new!(name, [
          %Stage{
            name: :fixture,
            nodes: [%Node{name: :fixture, prompt: "fixture only", schema: %{}}]
          }
        ])
    })

    put_env!(:routines, [
      %{
        id: caretaker,
        role: :caretaker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "Synthetic conformance fixture",
        on_note: :ignore
      }
    ])

    on_exit(fn ->
      run_ids = Repo.all(from(r in Run.Row, where: r.repo == ^repo, select: r.run_id))

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) in ^run_ids
        )
      )

      Repo.delete_all(from(r in Run.Row, where: r.repo == ^repo))

      Repo.delete_all(
        from(f in Feed.Entry, where: fragment("json_extract(?, '$.repo')", f.entry) == ^repo)
      )

      Repo.delete_all(
        from(row in AgentAuthorizationSnapshot, where: row.routine_id == ^caretaker)
      )
    end)

    %{name: name, repo: repo, caretaker: caretaker}
  end

  for protocol <- ["2025-11-25", "2026-07-28"] do
    @protocol protocol

    test "an independent HTTP client proves workflow decisions for #{@protocol}", ctx do
      prove_conformance(ctx, @protocol)
    end
  end

  defp prove_conformance(ctx, protocol) do
    assert Mix.env() == :test
    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false

    port = Application.fetch_env!(:custode, :mcp_port)
    assert is_integer(port) and port > 0
    url = Custode.MCP.url()
    assert URI.parse(url).port == port
    python = System.find_executable("python3")
    assert python, "Python 3 is required for the independent MCP proof"

    # The client discovers these itself; their IDs are never handed to it up front.
    proposals =
      for _ <- 1..3 do
        {:ok, proposal} = Launch.propose(ctx.name, ctx.repo, budget_usd: 2.5)
        proposal.id
      end

    baseline = dispatch_counts()
    operator_token = Identity.mint(:operator, uid("conformance-human"))
    routine_token = Identity.mint(:routine, ctx.caretaker)

    {output, status} =
      System.cmd(
        python,
        [
          Path.expand("scripts/mcp_workflow_conformance.py"),
          "--url",
          url,
          "--repo",
          ctx.repo,
          "--protocol",
          protocol
        ],
        env: [
          {"CUSTODE_CONFORMANCE_OPERATOR_TOKEN", operator_token},
          {"CUSTODE_CONFORMANCE_ROUTINE_TOKEN", routine_token},
          {"PYTHONDONTWRITEBYTECODE", "1"}
        ],
        stderr_to_stdout: true
      )

    runs = Repo.all(from(r in Run.Row, where: r.repo == ^ctx.repo))

    # Credentials and fixture identities live only in the child, never its output.
    output_safe =
      Enum.all?(
        [operator_token, routine_token, ctx.repo, ctx.name, ctx.caretaker] ++
          proposals ++ Enum.map(runs, & &1.run_id),
        &(not String.contains?(output, &1))
      )

    assert output_safe, "conformance output contains private fixture data"
    assert status == 0, output
    proof = Jason.decode!(output)
    assert proof["ok"] == true
    assert proof["protocol_versions"] == [protocol]
    assert proof["discovery_protocol_versions"] == ["2025-11-25", "2026-07-28"]

    expected_setup =
      if protocol == "2025-11-25",
        do: "initialize_and_initialized",
        else: "stateless_without_initialize"

    assert proof["protocol_setup"] == expected_setup
    assert proof["required_tools"] == 3
    assert proof["discovered_proposals"] == 3

    for check <- ~w(
          selected_protocol_journey discovery_schema_parity attention_discovery
          receipt_schema approval_retry rejection_retry opposite_stale_decision
          unknown_proposal http_authorization routine_refusal http200_tool_error
          jsonrpc_argument_error fresh_process_recovery
        ) do
      assert proof["checks"][check] == true, "missing proof: #{check}"
    end

    assert proof["recovery"] == %{
             "ok" => true,
             "reauthenticated" => true,
             "retained_approval" => true,
             "retained_rejection" => true,
             "retained_conflict" => true
           }

    # Approval admitted exactly one run with one initial job across every retry.
    assert [%{status: "running", budget_usd: 2.5} = run] = runs

    assert [job] =
             Repo.all(
               from(j in Oban.Job,
                 where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
               )
             )

    # Queues are disabled: the job was admitted and never attempted.
    assert job.attempt == 0 and job.state in ~w(available scheduled)
    assert Results.for_run(run.run_id) == []

    decisions =
      Repo.all(
        from(f in Feed.Entry,
          where:
            f.event in ["workflow_launch_approved", "workflow_launch_rejected"] and
              fragment("json_extract(?, '$.repo')", f.entry) == ^ctx.repo,
          select: f.entry
        )
      )
      |> Enum.map(&Jason.decode!/1)

    assert [approved] = Enum.filter(decisions, &(&1["event"] == "workflow_launch_approved"))
    assert [rejected] = Enum.filter(decisions, &(&1["event"] == "workflow_launch_rejected"))
    assert approved["run"] == run.run_id
    # Rejection creates no run, and the first reason survives a later retry.
    assert rejected["run"] == nil
    assert rejected["reason"] == "Synthetic fixture rejection"

    assert [untouched] =
             Launch.pending()
             |> Enum.filter(&(&1["repo"] == ctx.repo))
             |> Enum.map(& &1["proposal"])

    assert Enum.sort([approved["proposal"], rejected["proposal"], untouched]) ==
             Enum.sort(proposals)

    assert dispatch_counts() == %{baseline | jobs: baseline.jobs + 1}
    assert Custode.InboxWakes.get(ctx.caretaker) == nil
  end

  defp dispatch_counts do
    %{
      jobs: Repo.aggregate(Oban.Job, :count),
      operator_messages: Repo.aggregate(OperatorMessage, :count),
      peer_messages: Repo.aggregate(PeerMessage, :count)
    }
  end
end
