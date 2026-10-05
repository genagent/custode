defmodule Custode.ReadCompositions.RestartProof do
  @moduledoc "Guarded isolated OS-process reconstruction, not native-host refresh evidence."
  alias Custode.MCP.Identity
  alias Custode.{ReadCompositions, Repo, Repository, Routine}
  alias Snodo.Client
  @human %{kind: :operator, id: "composition-proof-human"}
  @owner "composition-proof-owner"
  @peer "composition-proof-peer"
  @repo "fixture/composition-proof"
  @sources ~w(lib/custode/read_compositions/restart_proof.ex lib/mix/tasks/custode.composition.proof.ex lib/custode/read_compositions.ex lib/custode/mcp/read_composition_tools.ex mix.lock)

  defmodule Ops do
    @moduledoc false
    def view_pr(_owner, _repo, number), do: result(%{number: number, head_sha: "old-head"})
    def pr_checks(_owner, _repo, _number), do: result(%{sha: "new-head", checks: []})
    def pr_diff(_owner, _repo, _number), do: result(%{files: []})

    defp result(value) do
      Agent.update(Custode.CompositionProofReads, &(&1 + 1))
      {:ok, value}
    end
  end

  def run(options) do
    guard!(options.root)
    {:ok, _counter} = Agent.start_link(fn -> 0 end, name: Custode.CompositionProofReads)
    configure(options.root)
    Repository.ensure_served(@repo, @owner)
    manifest = manifest(options)
    manifest = phase(options.phase, manifest)
    write(options.root, "manifest.json", manifest)

    {:ok, listing} = ReadCompositions.list(@human)
    assert!(listing["activation"]["generation"] == expected_generation(options.phase))

    report = %{
      "schema" => "custode.composition-restart-proof.v1",
      "phase" => options.phase,
      "pid" => System.pid(),
      "source_revision" => source_revision(),
      "source_sha256" => source_hashes(),
      "definition_revisions" => [manifest["first"], manifest["second"]],
      "generation" => listing["activation"]["generation"],
      "native_model_calls" => 0,
      "status" => "passed",
      "limits" => "Controlled backend; real HTTP reconnect, not native session refresh."
    }

    write(options.root, options.phase <> "-result.json", report)
  end

  defp configure(root) do
    workspace = Path.join(root, "memory")
    File.mkdir_p!(workspace)

    routines =
      for id <- [@owner, @peer] do
        Routine.normalize_entry(%{
          id: id,
          provider: :claude,
          role: :backlog_worker,
          cron: :manual,
          repo: @repo,
          workspace: workspace,
          prompt: "Nonpaid proof; never execute."
        })
      end

    Application.put_env(:custode, :routines, routines)
    Application.put_env(:custode, :read_composition_owner, @owner)
    Application.put_env(:custode, :repo_ops, Ops)
  end

  defp manifest(%{phase: "init", root: root}) do
    for name <- @sources do
      path = Path.join([root, "source", name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, File.read!(name))
      File.chmod!(path, 0o600)
    end

    %{"source_revision" => source_revision(), "source_sha256" => source_hashes()}
  end

  defp manifest(options) do
    record = options.root |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    assert!(
      record["source_revision"] == source_revision() and
        record["source_sha256"] == source_hashes()
    )

    record
  end

  defp phase("init", record) do
    {:ok, first} = ReadCompositions.publish(@human, ReadCompositions.template(@repo))

    {:ok, second} =
      ReadCompositions.publish(
        @human,
        Map.put(ReadCompositions.template(@repo), "description", "Second retained presentation.")
      )

    assert!(first["revision"] != second["revision"])
    {:ok, _} = ReadCompositions.activate(@human, "pr_review_context", first["revision"], 0)
    exercise_http!(first["revision"])
    Map.merge(record, %{"first" => first["revision"], "second" => second["revision"]})
  end

  defp phase("reopen", record) do
    for revision <- [record["first"], record["second"]] do
      assert!(
        Repo.get!(ReadCompositions.Row, "definition:" <> revision).data["revision"] == revision
      )
    end

    exercise_http!(record["first"])
    {:ok, _} = ReadCompositions.activate(@human, "pr_review_context", record["second"], 1)
    exercise_http!(record["second"])
    {:ok, _} = ReadCompositions.activate(@human, "pr_review_context", nil, 2)
    assert!({:error, :composition_disabled} == invoke())
    {:ok, %{"entries" => []}} = ReadCompositions.list(%{kind: :routine, id: @owner})
    {:ok, _} = ReadCompositions.activate(@human, "pr_review_context", record["first"], 3)
    exercise_http!(record["first"])
    record
  end

  defp phase("final", record) do
    exercise_http!(record["first"])
    assert!(Repo.aggregate(ReadCompositions.Row, :count) >= 3)
    record
  end

  defp expected_generation("init"), do: 1
  defp expected_generation(_phase), do: 4

  defp exercise_http!(revision) do
    token = Identity.mint(:routine, @owner)

    {:ok, client} =
      Client.connect({:http, Custode.MCP.url()},
        protocol_version: "2025-06-18",
        headers: [{"authorization", "Bearer " <> token}]
      )

    try do
      {:ok, result} = Client.call_tool(client, "read_composition", %{"request" => request()})
      %{"content" => [%{"text" => text}]} = result
      returned = Jason.decode!(text)
      assert!(returned["revision"] == revision and returned["status"] == "complete")
      assert!(returned["coherence"] =~ "diff_has_no_head_binding")
      {:ok, trace} = ReadCompositions.trace(%{kind: :routine, id: @owner}, returned["trace_id"])
      assert!(length(trace["steps"]) == 3 and trace["actor"]["id"] == @owner)
    after
      Client.close(client)
    end

    peer_token = Identity.mint(:routine, @peer)

    {:ok, peer_client} =
      Client.connect({:http, Custode.MCP.url()},
        headers: [{"authorization", "Bearer " <> peer_token}]
      )

    before = Agent.get(Custode.CompositionProofReads, & &1)

    try do
      refusal = Client.call_tool(peer_client, "read_composition", %{"request" => request()})
      assert!(match?({:error, _}, refusal) or match?({:ok, %{"isError" => true}}, refusal))
      assert!(Agent.get(Custode.CompositionProofReads, & &1) == before)
    after
      Client.close(peer_client)
    end

    assert!(
      {:error, :composition_not_granted} ==
        ReadCompositions.invoke(%{kind: :routine, id: @peer}, "pr_review_context", arguments())
    )
  end

  defp invoke,
    do: ReadCompositions.invoke(%{kind: :routine, id: @owner}, "pr_review_context", arguments())

  defp arguments, do: %{"repo" => @repo, "number" => 42}

  defp request,
    do: %{"action" => "invoke", "name" => "pr_review_context", "arguments" => arguments()}

  defp guard!(root) do
    assert!(
      Mix.env() == :test and System.get_env("CUSTODE_COMPOSITION_RESTART_PROOF") == "1" and
        Application.get_env(:custode, :composition_restart_proof_root) == root and
        Path.expand(Repo.config()[:database]) == Path.join(root, "operations.db") and
        Application.get_env(:custode, :oban_queues) == [] and
        Application.get_env(:custode, :scheduler_autostart) == false
    )
  end

  defp source_hashes do
    Map.new(@sources, fn name ->
      {name, :crypto.hash(:sha256, File.read!(name)) |> Base.encode16(case: :lower)}
    end)
  end

  defp source_revision do
    {text, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(text)
  end

  defp write(root, name, value) do
    path = Path.join(root, name)
    File.write!(path, Jason.encode!(value, pretty: true))
    File.chmod!(path, 0o600)
  end

  defp assert!(true), do: :ok
  defp assert!(_other), do: raise("composition reconstruction assertion failed")
end
