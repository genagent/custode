defmodule Custode.NativeCompositionTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Custode.MCP.Identity
  alias Custode.ReadCompositions
  alias Custode.Repository

  defmodule Ops do
    def view_pr(_owner, _repo, number),
      do: record("repo_view_pr", %{number: number, head_sha: "fixture-old-head"})

    def pr_checks(_owner, _repo, _number) do
      record("repo_pr_checks", %{sha: "fixture-new-head", checks: []})
    end

    def pr_diff(_owner, _repo, _number),
      do: record("repo_pr_diff", %{files: [%{filename: "fixture.ex", patch: "fixture diff"}]})

    defp record(tool, value) do
      Agent.update(Application.fetch_env!(:custode, :native_proof_collector), &[tool | &1])

      if tool == "repo_pr_checks" and Application.get_env(:custode, :native_proof_partial),
        do: {:error, :controlled_read_failure},
        else: {:ok, value}
    end
  end

  test "native observation parser checks run without inference" do
    {output, code} =
      System.cmd("python3", ["-B", "-m", "unittest", "test_native_composition"],
        cd: "spikes/capabilities",
        stderr_to_stdout: true
      )

    assert code == 0, output
  end

  @tag :preview
  @tag timeout: 1_200_000
  test "actual Claude and Codex compare fixed composition with three reads" do
    assert System.get_env("CUSTODE_NATIVE_COMPOSITION_PROOF") == "1",
           "Explicit CUSTODE_NATIVE_COMPOSITION_PROOF=1 is required for paid native runs"

    report_path = System.fetch_env!("CUSTODE_NATIVE_COMPOSITION_REPORT")
    owner = routine_fixture!(tmp_workspace!(), %{repo: "acme/" <> uid("native-proof")})
    put_env!(:read_composition_owner, owner.id)
    put_env!(:repo_ops, Ops)
    put_env!(:native_proof_partial, false)
    {:ok, collector} = Agent.start_link(fn -> [] end)
    put_env!(:native_proof_collector, collector)
    Repository.ensure_served(owner.repo, owner.id)
    actor = %{kind: :operator, id: "native-proof-human"}
    {:ok, definition} = ReadCompositions.publish(actor, ReadCompositions.template(owner.repo))

    {:ok, _activation} =
      ReadCompositions.activate(actor, "pr_review_context", definition["revision"], 0)

    token = Identity.mint(:routine, owner.id)
    directory = tmp_workspace!()
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    private_logs = report_path <> ".raw"
    File.mkdir_p!(private_logs)
    File.chmod!(private_logs, 0o700)
    {source, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    baseline = %{
      "source_revision" => String.trim(source),
      "definition_revision" => definition["revision"],
      "caller" => %{"kind" => "routine", "id" => owner.id},
      "backend" => "controlled Ops fixture, not live GitHub",
      "context_bytes" => "proxy-returned tool text, not confirmed model consumption",
      "snodo_lock_sha256" =>
        :crypto.hash(:sha256, File.read!("mix.lock")) |> Base.encode16(case: :lower),
      "controlled_mismatching_heads" => ["fixture-old-head", "fixture-new-head"],
      "diff_binding" => "unavailable",
      "catalog_refresh_notifications" => "not_proven",
      "results" => []
    }

    report =
      for provider <-
            String.split(
              System.get_env("CUSTODE_NATIVE_COMPOSITION_PROVIDERS", "claude,codex"),
              ","
            ),
          scenario <- ["original", "composition", "partial", "denied"],
          reduce: baseline do
        report ->
          Agent.update(collector, fn _reads -> [] end)
          Application.put_env(:custode, :native_proof_partial, scenario == "partial")
          config_path = Path.join(directory, "request.json")

          config = %{
            "provider" => provider,
            "codex_model" => System.get_env("CUSTODE_NATIVE_CODEX_MODEL", "gpt-6.1-sol"),
            "scenario" => scenario,
            "repo" => if(scenario == "denied", do: "outside/repo", else: owner.repo),
            "url" => Custode.MCP.url(),
            "token" => token,
            "private_logs" => private_logs
          }

          File.write!(config_path, Jason.encode!(config))
          File.chmod!(config_path, 0o600)

          result =
            Forcola.run(
              [
                System.find_executable("python3"),
                "-B",
                Path.expand("spikes/capabilities/native_composition.py"),
                config_path
              ],
              timeout_ms: 110_000,
              merge_stderr: false
            )

          measurement = measurement(result)
          backend_reads = Agent.get(collector, &Enum.reverse/1)
          measurement = Map.put(measurement, "backend_reads", backend_reads)

          traces =
            Enum.flat_map(measurement["http"], fn call ->
              if id = call["trace_id"] do
                {:ok, trace} = ReadCompositions.trace(%{kind: :routine, id: owner.id}, id)

                [
                  %{
                    "trace_id" => id,
                    "revision" => trace["revision"],
                    "actor" => trace["actor"],
                    "status" => trace["status"]
                  }
                ]
              else
                []
              end
            end)

          measurement = Map.put(measurement, "traces", traces)
          next = Map.update!(report, "results", &(&1 ++ [measurement]))
          File.write!(report_path, Jason.encode!(next, pretty: true))
          File.chmod!(report_path, 0o600)
          File.rm!(config_path)
          assert get_in(measurement, ["client", "exit_code"]) == 0, inspect(measurement)
          assert is_binary(get_in(measurement, ["client", "session_id"])), inspect(measurement)
          refute get_in(measurement, ["client", "native_error"]), inspect(measurement)
          next
      end

    for measurement <- report["results"] do
      assert get_in(measurement, ["client", "exit_code"]) == 0, inspect(measurement)
      assert is_binary(get_in(measurement, ["client", "session_id"])), inspect(measurement)
      calls = Enum.filter(measurement["http"], &(&1["method"] == "tools/call"))
      scenario = measurement["scenario"]
      assert length(calls) == if(scenario == "original", do: 3, else: 1), inspect(measurement)

      expected =
        if scenario == "original",
          do: ~w(repo_view_pr repo_pr_checks repo_pr_diff),
          else: ["read_composition"]

      assert Enum.map(calls, & &1["tool"]) == expected
      assert measurement["client"]["capture"] == "returned"
      refute measurement["client"]["native_error"]
      assert measurement["client"]["terminal_event"] in ["success", "turn.completed"]
      assert length(measurement["backend_reads"]) == expected_reads(scenario)

      assert measurement["backend_reads"] ==
               Enum.take(~w(repo_view_pr repo_pr_checks repo_pr_diff), expected_reads(scenario))

      if scenario in ["composition", "partial"] do
        assert length(measurement["traces"]) == 1

        assert hd(measurement["traces"])["status"] ==
                 if(scenario == "composition", do: "complete", else: "dependency_read_failed")
      end

      for trace <- measurement["traces"] do
        assert trace["revision"] == definition["revision"]
        assert trace["actor"] == %{"kind" => "routine", "id" => owner.id}
      end

      case scenario do
        "denied" ->
          assert hd(calls)["failed"]

        "partial" ->
          assert hd(calls)["composition_status"] == "dependency_read_failed"
          assert is_binary(hd(calls)["trace_id"])

        _ ->
          refute Enum.any?(calls, & &1["failed"])

          assert Enum.sort(Enum.flat_map(calls, & &1["observed_heads"])) ==
                   ~w(fixture-new-head fixture-old-head)

          assert measurement["client"]["interpretation"]["old_head"]
          assert measurement["client"]["interpretation"]["new_head"]
          assert measurement["client"]["interpretation"]["mismatch"]
      end
    end
  end

  defp expected_reads("denied"), do: 0
  defp expected_reads("partial"), do: 2
  defp expected_reads(_scenario), do: 3

  defp measurement({:ok, %Forcola.Result{status: 0, stdout: output}}),
    do: Jason.decode!(String.trim(output))

  defp measurement(_unconfirmed),
    do: %{"client" => %{"exit_code" => nil}, "http" => [], "scenario" => "unconfirmed"}
end
