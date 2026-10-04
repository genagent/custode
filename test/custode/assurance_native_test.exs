defmodule Custode.Assurance.NativeTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Custode.{Assurance, Repo}
  alias Custode.Assurance.Native

  @human %{kind: :operator, id: "synthetic-native-harness"}
  @fixture Path.expand("../fixtures/assurance_native_cli.py", __DIR__)

  setup do
    put_env!(:assurance_native_enabled, true)
    original_user = System.get_env("USER")
    System.put_env("USER", original_user || "synthetic-native-user")

    on_exit(fn ->
      if original_user, do: System.put_env("USER", original_user), else: System.delete_env("USER")
    end)

    on_exit(fn ->
      Repo.delete_all(Native.Row)
      Repo.delete_all(Assurance.Row)
    end)

    :ok
  end

  test "configured native execution freezes actual recorded identity, checks and separate opinion" do
    ctx = context()
    {:ok, producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
    assert producer["status"] == "completed"
    assert producer["runner"]["stdin_mode"] == "null"
    assert producer["runner"]["runner_version"] == "verification-runner-v3"
    assert producer["observed"]["observed_model"] == "synthetic-claude-model"
    assert producer["physical_settlement"]["all_descendants_attestation"] == "missing"
    assert Enum.at(producer["argv"], -2) == "--"
    assert "--effort" in producer["argv"]
    assert "{\"disableAllHooks\":true}" in producer["argv"]
    assert {:ok, ^producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
    assert calls(ctx) == ["claude"]

    assert {:error, :idempotency_conflict} =
             Native.launch(@human, ctx.id, %{launch(ctx, "produce", 1) | "generation" => 2})

    assert calls(ctx) == ["claude"]

    freeze(ctx, producer)
    {:ok, verifier} = Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
    {:ok, check} = capture(ctx, verifier, "check", "native_check")
    {:ok, opinion} = capture(ctx, verifier, "opinion", "native_opinion")
    assert check["claim_class"] == "independently_reproduced"
    assert check["outcome"] == "passed"
    assert opinion["claim_class"] == "independent_opinion"
    assert verifier["observed"]["observed_model"] == nil
    assert check["execution"]["requested_effort"] == "low"
    assert check["execution"]["observed_effort"] == nil
    refute Map.has_key?(check["snapshot"], "native")
    refute inspect(check["snapshot"]) =~ "captured_base64"
    assert calls(ctx) == ["claude", "codex"]
    assert {:ok, ^verifier} = Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
    assert calls(ctx) == ["claude", "codex"]

    assert {:error, :unsettled_workspace_already_claimed} =
             Native.launch(@human, ctx.id, %{
               launch(ctx, "verify", 2)
               | "request_id" => uid("repeat")
             })

    # Evidence reads only immutable captured records, even if the workspace later disappears.
    File.rm_rf!(ctx.verifier)
    assert {:ok, recaptured} = capture(ctx, verifier, "check", "native_check", uid("recapture"))
    assert Map.drop(recaptured, ["id", "recorded_at"]) == Map.drop(check, ["id", "recorded_at"])
  end

  test "exact shell wrapper argv forms bind the recorder-controlled absolute cwd" do
    for mode <- ~w(single double warning) do
      ctx = context(mode)
      {:ok, producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
      freeze(ctx, producer)
      {:ok, verifier} = Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
      {:ok, check} = capture(ctx, verifier, "check", "native_check")
      assert check["claim_class"] == "independently_reproduced"
      assert check["outcome"] == "passed"
      if mode == "warning", do: assert(length(check["snapshot"]["diagnostics"]) == 1)
    end
  end

  test "other-cwd commands and forged emitted check binding remain unknown" do
    for mode <-
          ~w(outside-cwd forged-output bad-row ambiguous-json unknown-diagnostic failed-zero) do
      ctx = context(mode)
      {:ok, producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
      freeze(ctx, producer)
      {:ok, verifier} = Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
      {:ok, check} = capture(ctx, verifier, "check", "native_check")
      assert check["claim_class"] == "host_observed"
      assert check["outcome"] == "unknown"
      refute check["missing_bindings"] == []
    end
  end

  test "different request ids cannot concurrently own one physical workspace" do
    ctx = context()
    File.write!(Path.join(ctx.root, "block"), "hold")
    task = Task.async(fn -> Native.launch(@human, ctx.id, launch(ctx, "produce", 1)) end)
    assert wait_until(fn -> File.exists?(Path.join(ctx.root, "started")) end)

    assert {:error, :unsettled_workspace_already_claimed} =
             Native.launch(@human, ctx.id, %{
               launch(ctx, "produce", 1)
               | "request_id" => uid("parallel")
             })

    assert calls(ctx) == ["claude"]
    File.rm!(Path.join(ctx.root, "block"))
    assert {:ok, %{"status" => "completed"}} = Task.await(task, 10_000)
  end

  test "admission revalidates owner, selected profile and policy after the native version probe" do
    for change <- [:owner, :profile, :policy] do
      ctx = context()
      File.write!(Path.join(ctx.root, "version-block"), "hold")
      task = Task.async(fn -> Native.launch(@human, ctx.id, launch(ctx, "produce", 1)) end)
      assert wait_until(fn -> File.exists?(Path.join(ctx.root, "version-started")) end)

      case change do
        :owner ->
          put_env!(
            :routines,
            Enum.map(Application.get_env(:custode, :routines), fn actor ->
              if actor.working_dir == ctx.producer,
                do: Map.put(actor, :model, "changed"),
                else: actor
            end)
          )

        :profile ->
          put_env!(
            :assurance_native_profiles,
            Enum.map(Application.get_env(:custode, :assurance_native_profiles), fn profile ->
              if profile["id"] == ctx.id <> "-produce",
                do: Map.put(profile, "timeout_ms", 9_000),
                else: profile
            end)
          )

        :policy ->
          put_env!(
            :assurance_assignments,
            Enum.map(Application.get_env(:custode, :assurance_assignments), fn assignment ->
              if assignment["id"] == ctx.id,
                do: Map.put(assignment, "criteria", ["Changed acceptance criteria."]),
                else: assignment
            end)
          )
      end

      File.rm!(Path.join(ctx.root, "version-block"))
      assert {:error, :native_admission_changed} = Task.await(task, 10_000)
      refute File.exists?(Path.join(ctx.root, "calls"))
      refute Repo.get(Native.Row, ctx.id <> "-produce")
    end
  end

  test "an actual deterministic rerun contradicts the seeded baseline even when the wrapper is valid" do
    ctx = context("seeded")
    {:ok, producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
    freeze(ctx, producer)
    {:ok, verifier} = Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
    {:ok, check} = capture(ctx, verifier, "check", "native_check")
    {:ok, opinion} = capture(ctx, verifier, "opinion", "native_opinion")
    assert check["claim_class"] == "independently_reproduced"
    assert check["outcome"] == "failed"
    assert opinion["outcome"] == "failed"
  end

  test "owner loss leaves an unresolved workspace lock and never redelivers automatically" do
    ctx = context()
    File.write!(Path.join(ctx.root, "block"), "hold")
    owner = spawn(fn -> Native.launch(@human, ctx.id, launch(ctx, "produce", 1)) end)
    assert wait_until(fn -> File.exists?(Path.join(ctx.root, "started")) end)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert {:ok, pending} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
    assert pending["status"] == "running"
    assert pending["physical_settlement"]["all_descendants_attestation"] == "missing"

    assert {:error, :unsettled_workspace_already_claimed} =
             Native.launch(@human, ctx.id, %{
               launch(ctx, "produce", 1)
               | "request_id" => uid("redeliver")
             })

    assert calls(ctx) == ["claude"]
    # Test-owned fixture cleanup is not promoted to a production settlement attestation.
    File.rm!(Path.join(ctx.root, "block"))
    pid = File.read!(Path.join(ctx.root, "started"))
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
  end

  test "source capture refuses stale generations and caller-issued source claims" do
    ctx = context()
    {:ok, producer} = Native.launch(@human, ctx.id, launch(ctx, "produce", 1))
    freeze(ctx, producer)

    assert {:error, :stale_generation_or_artifact} =
             Native.launch(@human, ctx.id, %{launch(ctx, "verify", 2) | "generation" => 1})

    assert {:error, :invalid_arguments} =
             Native.launch(
               @human,
               ctx.id,
               Map.put(launch(ctx, "verify", 2), "trust_class", "independently_reproduced")
             )

    assert {:error, :stale_generation} =
             Assurance.capture(@human, ctx.id, %{
               "request_id" => uid("stale"),
               "generation" => 1,
               "predicate" => "check",
               "source" => %{"kind" => "native_check", "native_run_id" => producer["id"]}
             })

    put_env!(:assurance_native_enabled, false)

    assert {:error, :native_proof_disabled} =
             Native.launch(@human, ctx.id, launch(ctx, "verify", 2))
  end

  defp context(mode \\ "direct") do
    root = tmp_workspace!()
    base = Path.join(root, "base")
    producer = Path.join(root, "producer")
    verifier = Path.join(root, "verifier")
    File.mkdir!(base)

    for file <- ~w(baseline.py verify.py),
        do:
          File.cp!(
            Application.app_dir(:custode, "priv/assurance_native/" <> file),
            Path.join(base, file)
          )

    if mode == "seeded",
      do:
        File.write!(Path.join(base, "baseline.py"), "def baseline_add(a, b):\n    return a - b\n")

    git(base, ["init", "--initial-branch=main"])
    git(base, ["config", "user.name", "joshrotenberg"])
    git(base, ["config", "user.email", "joshrotenberg@gmail.com"])
    git(base, ["add", "."])
    git(base, ["-c", "commit.gpgsign=false", "commit", "-m", "test: fixture"])
    revision = git(base, ["rev-parse", "HEAD"])
    git(base, ["worktree", "add", "--detach", producer, revision])
    File.write!(Path.join(root, "mode"), mode)
    File.chmod!(@fixture, 0o755)
    id = uid("native-case")

    owner = %{
      id: uid("native-owner"),
      provider: :claude,
      model: "sonnet",
      effort: "low",
      working_dir: producer,
      workspace: tmp_workspace!(),
      repo: "acme/native",
      cron: "@daily",
      prompt: "fixture"
    }

    peer = %{
      owner
      | id: uid("native-peer"),
        provider: :codex,
        model: "gpt-5.5",
        working_dir: verifier,
        workspace: tmp_workspace!()
    }

    put_env!(:routines, Application.get_env(:custode, :routines, []) ++ [owner, peer])

    assignment = %{
      "id" => id,
      "owner_id" => owner.id,
      "judge_id" => @human.id,
      "max_rounds" => 2,
      "criteria" => ["Pinned check and other-provider opinion."],
      "policy" => %{
        "predicates" => [
          %{
            "name" => "check",
            "sources" => ["native_check"],
            "classes" => ["independently_reproduced"],
            "independent" => true
          },
          %{
            "name" => "opinion",
            "sources" => ["native_opinion"],
            "classes" => ["independent_opinion"],
            "independent" => true
          }
        ]
      }
    }

    put_env!(
      :assurance_assignments,
      Application.get_env(:custode, :assurance_assignments, []) ++ [assignment]
    )

    profiles =
      for {actor, role} <- [{owner, "produce"}, {peer, "verify"}],
          do: %{
            "id" => id <> "-" <> role,
            "owner_id" => owner.id,
            "actor_id" => actor.id,
            "role" => if(role == "produce", do: "producer", else: "verifier"),
            "provider" => to_string(actor.provider),
            "binary" => @fixture,
            "model" => actor.model,
            "effort" => "low",
            "working_dir" => actor.working_dir,
            "timeout_ms" => 10_000,
            "max_budget_usd" => 0.5
          }

    put_env!(
      :assurance_native_profiles,
      Application.get_env(:custode, :assurance_native_profiles, []) ++ profiles
    )

    request = %{
      "case_id" => id,
      "assignment_id" => id,
      "objective" => "Fixed synthetic execution test.",
      "input" =>
        Jason.encode!(%{
          "producer_file" => "submission.py",
          "producer_request" => "Create exact fixture wrapper.",
          "check" => "python3 -B verify.py",
          "check_file" => "verify.py",
          "check_sha256" => digest(File.read!(Path.join(base, "verify.py")))
        }),
      "artifact" => %{"kind" => "repository", "repository" => owner.repo, "revision" => revision}
    }

    {:ok, _case} = Assurance.open(@human, request)
    %{root: root, base: base, producer: producer, verifier: verifier, id: id, request: request}
  end

  defp freeze(ctx, producer) do
    git(ctx.base, ["worktree", "add", "--detach", ctx.verifier, producer["produced_revision"]])

    {:ok, _attempt} =
      Assurance.revise(@human, ctx.id, %{
        "request_id" => ctx.id <> "-freeze",
        "generation" => 1,
        "objective" => ctx.request["objective"],
        "input" => ctx.request["input"],
        "producer_native_run_id" => producer["id"],
        "artifact" => Map.put(ctx.request["artifact"], "revision", producer["produced_revision"])
      })
  end

  defp launch(ctx, role, generation),
    do: %{
      "request_id" => ctx.id <> "-" <> role,
      "profile_id" => ctx.id <> "-" <> role,
      "generation" => generation
    }

  defp capture(ctx, verifier, predicate, kind, id \\ nil),
    do:
      Assurance.capture(@human, ctx.id, %{
        "request_id" => id || ctx.id <> "-" <> predicate,
        "generation" => 2,
        "predicate" => predicate,
        "source" => %{"kind" => kind, "native_run_id" => verifier["id"]}
      })

  defp calls(ctx), do: File.read!(Path.join(ctx.root, "calls")) |> String.split("\n", trim: true)

  defp git(path, args) do
    {output, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    String.trim(output)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp wait_until(fun, left \\ 200)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, left),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            wait_until(fun, left - 1)
          )
      )
end
