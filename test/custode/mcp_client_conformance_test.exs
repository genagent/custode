defmodule Custode.MCPClientConformanceTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, OperatorMessage, PeerMessage, Repo}
  alias Custode.MCP.Identity

  @moduletag timeout: 120_000

  setup do
    owner = uid("conformance-owner")

    put_env!(:routines, [
      %{
        id: owner,
        role: :backlog_worker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "Synthetic conformance fixture",
        on_note: :ignore
      }
    ])

    on_exit(fn ->
      agreement_ids =
        Repo.all(
          from(row in "work_agreements",
            where: row.routine_id == ^owner,
            select: row.agreement_id
          )
        )

      Repo.delete_all(
        from(row in "work_agreement_records", where: row.agreement_id in ^agreement_ids)
      )

      Repo.delete_all(from(row in "work_agreements", where: row.routine_id == ^owner))
      Repo.delete_all(from(row in AgentAuthorizationSnapshot, where: row.routine_id == ^owner))
    end)

    %{owner: owner}
  end

  for protocol <- ["2025-11-25", "2026-07-28"] do
    @protocol protocol

    test "an independent HTTP client proves agreement conformance for #{@protocol}", %{
      owner: owner
    } do
      prove_conformance(owner, @protocol)
    end
  end

  defp prove_conformance(owner, protocol) do
    assert Mix.env() == :test
    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false
    assert Application.get_env(:custode, :github_fetcher) == Custode.Test.FakeGitHubFetcher

    # The test config honors an optional port override and its isolated default.
    port = Application.fetch_env!(:custode, :mcp_port)
    assert is_integer(port) and port > 0
    url = Custode.MCP.url()
    assert URI.parse(url).port == port
    assert Application.fetch_env!(:custode, :mcp_config_dir) == "tmp/test/mcp"
    python = System.find_executable("python3")
    assert python, "Python 3 is required for the independent MCP proof"

    baseline = dispatch_counts()
    operator_token = Identity.mint(:operator, uid("conformance-human"))
    routine_token = Identity.mint(:routine, owner)

    {output, status} =
      System.cmd(
        python,
        [
          Path.expand("scripts/mcp_conformance.py"),
          "--url",
          url,
          "--owner",
          owner,
          "--protocol",
          protocol
        ],
        env: [
          {"CUSTODE_CONFORMANCE_OPERATOR_TOKEN", operator_token},
          {"CUSTODE_CONFORMANCE_ROUTINE_TOKEN", routine_token}
        ],
        stderr_to_stdout: true
      )

    # Credentials live only in the child environment, never process arguments or output.
    output_safe =
      Enum.all?([operator_token, routine_token, owner], fn private ->
        not String.contains?(output, private)
      end)

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

    assert Enum.sort(proof["schema_versions"]) ==
             Enum.sort(~w(
               custode.project_progress.v1
               custode.project_report_digest.v1
               custode.work_agreement_mutation.v1
               custode.work_agreement.v1
               custode.work_agreement_list.v1
             ))

    assert proof["required_tools"] == 8

    for check <- ~w(
          selected_protocol_journey discovery_schema_parity
          configured_owner_reads stable_retry exact_acceptance stale_resolution
          http_authorization jsonrpc_error http200_tool_error human_only_resolution
          fresh_process_recovery
        ) do
      assert proof["checks"][check] == true, "missing proof: #{check}"
    end

    assert proof["recovery"] == %{
             "agreements" => 2,
             "history_records" => 5,
             "list_pages" => 2,
             "history_pages" => 5,
             "revision_bound_recovery" => true
           }

    assert dispatch_counts() == baseline
    assert Custode.InboxWakes.get(owner) == nil
  end

  defp dispatch_counts do
    %{
      jobs: Repo.aggregate(Oban.Job, :count),
      operator_messages: Repo.aggregate(OperatorMessage, :count),
      peer_messages: Repo.aggregate(PeerMessage, :count)
    }
  end
end
