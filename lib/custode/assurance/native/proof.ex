defmodule Custode.Assurance.Native.Proof do
  @moduledoc """
  Fixed, explicit native proof orchestration. Four calls maximum, no retries.
  Judgment belongs to the synthetic host harness, never to the human operator.
  Raw records remain in the private proof store; this is not a fleet runner.
  """
  alias Custode.{Assurance, Repo}
  alias Custode.Assurance.Native

  @human %{kind: :operator, id: "proof-harness-795"}
  @objective "Provide sum_pair(a,b), delegating exactly to baseline_add(a,b), and verify both functions compute addition."
  @keys [:routines, :assurance_assignments, :assurance_native_profiles, :assurance_native_enabled]

  def run(options) do
    root = Path.expand(options.root)
    guard!(root)
    saved = Map.new(@keys, &{&1, Application.fetch_env(:custode, &1)})
    report = initial_report(root)
    save(root, report)

    try do
      cases = for variant <- ~w(clean seeded), do: prepare_case(root, variant, options)
      configure(cases)

      report =
        Enum.reduce(cases, report, fn ctx, accumulated ->
          result = run_case(root, ctx)

          next =
            root
            |> Path.join("result.json")
            |> File.read!()
            |> Jason.decode!()
            |> Map.put("cases", accumulated["cases"] ++ [result])

          save(root, next)
          next
        end)

      passed = Enum.all?(report["cases"], & &1["passed"])
      report = Map.put(report, "status", if(passed, do: "passed", else: "incomplete"))
      save(root, report)
      report
    rescue
      error ->
        report = root |> Path.join("result.json") |> File.read!() |> Jason.decode!()

        report =
          Map.merge(report, %{"status" => "incomplete", "error" => Exception.message(error)})

        save(root, report)
        reraise(error, __STACKTRACE__)
    after
      for {key, value} <- saved do
        case value do
          {:ok, previous} -> Application.put_env(:custode, key, previous)
          :error -> Application.delete_env(:custode, key)
        end
      end
    end
  end

  @doc "Reassess retained native streams without launching any provider or replacing old receipts."
  def reassess(options) do
    root = Path.expand(options.root)
    guard!(root)
    original_bytes = File.read!(Path.join(root, "result.json"))
    original = Jason.decode!(original_bytes)
    revision = git!(File.cwd!(), ["rev-parse", "HEAD"])
    saved = Map.new(@keys, &{&1, Application.fetch_env(:custode, &1)})

    try do
      cases = Enum.map(original["cases"], &restore_case(root, &1))
      configure(cases)
      Application.put_env(:custode, :assurance_native_enabled, false)
      native_before = Repo.all(Native.Row)
      results = Enum.map(cases, &reassess_case(&1, revision))
      native_unchanged = Repo.all(Native.Row) == native_before

      report =
        original
        |> Map.put("native_launch_source_revision", original["source_revision"])
        |> Map.put("grading_source_revision", revision)
        |> Map.put("original_report_sha256", digest(original_bytes))
        |> Map.put("new_native_calls", 0)
        |> Map.put("native_records_unchanged", native_unchanged)
        |> Map.put("cases", results)
        |> Map.put(
          "status",
          if(native_unchanged and Enum.all?(results, & &1["passed"]),
            do: "passed",
            else: "incomplete"
          )
        )

      private_write(Path.join(root, "result-reassessed.json"), report)
      report
    after
      for {key, value} <- saved do
        case value do
          {:ok, previous} -> Application.put_env(:custode, key, previous)
          :error -> Application.delete_env(:custode, key)
        end
      end
    end
  end

  defp restore_case(root, initial) do
    id = initial["case_id"]
    variant = initial["variant"]
    unless variant in ~w(clean seeded), do: raise("unexpected recorded variant")
    directory = Path.join(root, variant)
    record = Repo.get!(Assurance.Row, "case:" <> id).record
    producer = Repo.get!(Native.Row, id <> "-produce").record
    verifier = Repo.get!(Native.Row, id <> "-verify").record

    unless producer["profile"]["working_dir"] == Path.join(directory, "producer") and
             verifier["profile"]["working_dir"] == Path.join(directory, "verifier"),
           do: raise("recorded proof workspace mismatch")

    owner = restored_routine(producer, directory)
    verifier_actor = restored_routine(verifier, directory)

    assignment = %{
      "id" => record["assignment_id"],
      "owner_id" => record["owner_id"],
      "judge_id" => record["current"]["judge_id"],
      "max_rounds" => record["max_rounds"],
      "criteria" => record["current"]["criteria"],
      "policy" => record["current"]["policy"]
    }

    %{
      id: id,
      variant: variant,
      base: Path.join(directory, "base"),
      owner: owner,
      verifier_actor: verifier_actor,
      assignment: assignment,
      profiles: [],
      retained_verifier: verifier,
      initial: initial
    }
  end

  defp restored_routine(native, directory) do
    profile = native["profile"]

    provider =
      case profile["provider"] do
        "claude" -> :claude
        "codex" -> :codex
      end

    %{
      id: profile["actor_id"],
      repo: "acme/" <> Path.basename(directory),
      provider: provider,
      model: profile["model"],
      effort: profile["effort"],
      working_dir: profile["working_dir"],
      workspace: Path.join(directory, profile["actor_id"] <> "-notebook"),
      cron: "@daily",
      prompt: "Explicit native proof only."
    }
  end

  defp reassess_case(ctx, revision) do
    request_id = ctx.id <> "-reassess-" <> revision

    {:ok, check} =
      Assurance.capture(
        @human,
        ctx.id,
        Map.merge(event(request_id <> "-check", 2), %{
          "predicate" => "check",
          "source" => %{
            "kind" => "native_check",
            "native_run_id" => ctx.retained_verifier["id"]
          }
        })
      )

    {:ok, repeated} =
      Assurance.capture(
        @human,
        ctx.id,
        Map.merge(event(request_id <> "-check", 2), %{
          "predicate" => "check",
          "source" => %{
            "kind" => "native_check",
            "native_run_id" => ctx.retained_verifier["id"]
          }
        })
      )

    {:ok, decision} = Assurance.decide(@human, ctx.id, event(request_id <> "-decision", 2))
    {:ok, projection} = Assurance.read(@human, ctx.id)
    opinion = ctx.initial["opinion_receipt"]

    controls =
      ctx.initial["controls"]
      |> Map.put("duplicate_capture_no_new_effect", repeated == check)
      |> Map.put("effect_authority_none", projection["effect_authority"] == "none")
      |> Map.put("sqlite_store_process_reopen_preserves_native_evidence", reopen(ctx, projection))

    expected = if ctx.variant == "clean", do: "accepted", else: "rejected"

    passed =
      decision["status"] == expected and
        check["claim_class"] == "independently_reproduced" and
        opinion["claim_class"] == "independent_opinion" and
        outcomes?(ctx.variant, check, opinion, decision) and Enum.all?(Map.values(controls), & &1)

    ctx.initial
    |> Map.put("initial_check_receipt", ctx.initial["check_receipt"])
    |> Map.put("initial_decision", ctx.initial["decision"])
    |> Map.put("initial_controls", ctx.initial["controls"])
    |> Map.put("check_receipt", Map.drop(check, ["snapshot"]))
    |> Map.put("decision", decision)
    |> Map.put("controls", controls)
    |> Map.put("passed", passed)
  end

  defp guard!(root) do
    database = Path.expand(Repo.config()[:database])

    unless Mix.env() == :test and System.get_env("CUSTODE_NATIVE_ASSURANCE_PROOF") == "1" and
             Application.get_env(:custode, :assurance_native_proof_root) == root and
             database == Path.join(root, "operations.db") and
             Application.get_env(:custode, :oban_queues) == [] and
             Application.get_env(:custode, :scheduler_autostart) == false do
      raise "native proof requires the guarded task and its isolated test store"
    end
  end

  defp initial_report(root) do
    %{
      "schema" => "custode.native-assurance-proof.v1",
      "status" => "running",
      "source_revision" => git!(File.cwd!(), ["rev-parse", "HEAD"]),
      "private_store" => Path.join(root, "operations.db"),
      "judge" => "synthetic_host_proof_harness_not_human_approval",
      "effect_authority" => "none",
      "cases" => [],
      "native_calls" => [],
      "limits" => [
        "no_all_descendants_attestation_or_automatic_redelivery",
        "four_configured_calls_no_automatic_retry",
        "claude_budget_stop_not_total_billing_ceiling_codex_cost_unknown",
        "fixture_defect_seed_and_git_commits_owned_by_host_harness",
        "repository_check_is_small_fixed_contract_not_general_provider_correctness"
      ]
    }
  end

  defp prepare_case(root, variant, options) do
    directory = Path.join(root, variant)
    File.mkdir!(directory)
    base = Path.join(directory, "base")
    File.mkdir!(base)
    fixture = Application.app_dir(:custode, "priv/assurance_native")

    for file <- ~w(baseline.py verify.py),
        do: File.cp!(Path.join(fixture, file), Path.join(base, file))

    if variant == "seeded" do
      path = Path.join(base, "baseline.py")
      File.write!(path, File.read!(path) |> String.replace("return a + b", "return a - b"))
    end

    init_repo(base)
    revision = git!(base, ["rev-parse", "HEAD"])
    producer = Path.join(directory, "producer")
    verifier = Path.join(directory, "verifier")
    git!(base, ["worktree", "add", "--detach", producer, revision])
    File.mkdir!(verifier)
    prefix = "native-795-" <> variant <> "-" <> Ecto.UUID.generate()

    owner =
      routine(
        prefix <> "-owner",
        producer,
        directory,
        :claude,
        options[:claude_model] || "sonnet"
      )

    verifier_actor =
      routine(
        prefix <> "-verifier",
        verifier,
        directory,
        :codex,
        options[:codex_model] || "gpt-5.5"
      )

    check_sha = digest(File.read!(Path.join(base, "verify.py")))

    %{
      id: prefix,
      variant: variant,
      base: base,
      base_revision: revision,
      producer: producer,
      verifier: verifier,
      owner: owner,
      verifier_actor: verifier_actor,
      assignment: assignment(prefix, owner.id),
      profiles: [
        profile(prefix <> "-produce", owner, "producer"),
        profile(prefix <> "-verify", verifier_actor, "verifier")
      ],
      input:
        Jason.encode!(%{
          "producer_file" => "submission.py",
          "producer_request" =>
            "Create submission.py containing only: from baseline import baseline_add; then def sum_pair(a, b): return baseline_add(a, b). Use conventional Python newlines. Do not inspect or repair baseline.py; the independent verifier checks it.",
          "check" => "python3 -B verify.py",
          "check_file" => "verify.py",
          "check_sha256" => check_sha
        })
    }
  end

  defp init_repo(path) do
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "joshrotenberg"])
    git!(path, ["config", "user.email", "joshrotenberg@gmail.com"])
    git!(path, ["add", "--", "baseline.py", "verify.py"])

    git!(path, [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "test: freeze host-owned assurance fixture"
    ])
  end

  defp routine(id, working_dir, directory, provider, model) do
    workspace = Path.join(directory, id <> "-notebook")
    File.mkdir!(workspace)

    %{
      id: id,
      repo: "acme/" <> Path.basename(directory),
      provider: provider,
      model: model,
      effort: "low",
      working_dir: working_dir,
      workspace: workspace,
      cron: "@daily",
      prompt: "Explicit native proof only."
    }
  end

  defp profile(id, actor, role) do
    %{
      "id" => id,
      "owner_id" => nil,
      "actor_id" => actor.id,
      "role" => role,
      "provider" => Atom.to_string(actor.provider),
      "binary" =>
        System.find_executable(Atom.to_string(actor.provider)) ||
          raise("native executable unavailable"),
      "working_dir" => actor.working_dir,
      "model" => actor.model,
      "effort" => "low",
      "timeout_ms" => 90_000,
      "max_budget_usd" => 0.5
    }
  end

  defp assignment(id, owner) do
    %{
      "id" => id,
      "owner_id" => owner,
      "judge_id" => @human.id,
      "max_rounds" => 2,
      "criteria" => [
        "The pinned deterministic check has ten correct addition rows.",
        "The cold other-provider verifier reports its own findings."
      ],
      "policy" => %{
        "predicates" => [
          predicate("check", "native_check", "independently_reproduced"),
          predicate("opinion", "native_opinion", "independent_opinion")
        ]
      }
    }
  end

  defp predicate(name, source, class),
    do: %{"name" => name, "sources" => [source], "classes" => [class], "independent" => true}

  defp configure(cases) do
    Application.put_env(:custode, :routines, Enum.flat_map(cases, &[&1.owner, &1.verifier_actor]))
    Application.put_env(:custode, :assurance_assignments, Enum.map(cases, & &1.assignment))

    profiles =
      for ctx <- cases, profile <- ctx.profiles, do: Map.put(profile, "owner_id", ctx.owner.id)

    Application.put_env(:custode, :assurance_native_profiles, profiles)
    Application.put_env(:custode, :assurance_native_enabled, true)
  end

  defp run_case(root, ctx) do
    request = %{
      "case_id" => ctx.id,
      "assignment_id" => ctx.id,
      "objective" => @objective,
      "input" => ctx.input,
      "artifact" => artifact(ctx, ctx.base_revision)
    }

    {:ok, _opened} = Assurance.open(@human, request)
    producer = launch(root, ctx, "produce", 1)
    revision = producer["produced_revision"] || raise "native producer did not retain an artifact"
    git!(ctx.base, ["worktree", "add", "--detach", ctx.verifier, revision])

    revise =
      Map.merge(event(ctx.id <> "-freeze", 1), %{
        "objective" => @objective,
        "input" => ctx.input,
        "artifact" => artifact(ctx, revision),
        "producer_native_run_id" => producer["id"]
      })

    {:ok, attempt} = Assurance.revise(@human, ctx.id, revise)
    verifier = launch(root, ctx, "verify", 2)
    check = capture(ctx, verifier, "check", "native_check")
    opinion = capture(ctx, verifier, "opinion", "native_opinion")
    judge(ctx)
    {:ok, decision} = Assurance.decide(@human, ctx.id, event(ctx.id <> "-decision", 2))
    controls = controls(ctx, revise, verifier, check)
    expected = if ctx.variant == "clean", do: "accepted", else: "rejected"

    passed =
      decision["status"] == expected and check["claim_class"] == "independently_reproduced" and
        opinion["claim_class"] == "independent_opinion" and
        outcomes?(ctx.variant, check, opinion, decision) and
        Enum.all?(Map.values(controls), & &1)

    %{
      "variant" => ctx.variant,
      "case_id" => ctx.id,
      "base_revision" => ctx.base_revision,
      "artifact_revision" => revision,
      "case_revision" => attempt["case_revision"],
      "producer" => native_summary(producer),
      "verifier" => native_summary(verifier),
      "check_receipt" => Map.drop(check, ["snapshot"]),
      "opinion_receipt" => Map.drop(opinion, ["snapshot"]),
      "decision" => decision,
      "controls" => controls,
      "passed" => passed
    }
  end

  defp outcomes?(variant, check, opinion, decision) do
    outcome = if variant == "clean", do: "passed", else: "failed"

    check["outcome"] == outcome and opinion["outcome"] == outcome and
      "designated_judge" in decision["satisfied"] and
      (variant == "clean" or "check" in decision["contradictory"])
  end

  defp artifact(ctx, revision),
    do: %{"kind" => "repository", "repository" => ctx.owner.repo, "revision" => revision}

  defp launch(root, ctx, role, generation) do
    {:ok, record} =
      Native.launch(@human, ctx.id, %{
        "request_id" => ctx.id <> "-" <> role,
        "profile_id" => ctx.id <> "-" <> role,
        "generation" => generation
      })

    private_write(Path.join(root, ctx.variant <> "-" <> role <> "-native.json"), record)
    progress = root |> Path.join("result.json") |> File.read!() |> Jason.decode!()
    save(root, Map.update!(progress, "native_calls", &(&1 ++ [native_summary(record)])))
    unless record["status"] == "completed", do: raise("native #{role} did not complete")
    record
  end

  defp capture(ctx, verifier, predicate, kind) do
    {:ok, receipt} =
      Assurance.capture(
        @human,
        ctx.id,
        Map.merge(event(ctx.id <> "-" <> predicate, 2), %{
          "predicate" => predicate,
          "source" => %{"kind" => kind, "native_run_id" => verifier["id"]}
        })
      )

    receipt
  end

  defp judge(ctx) do
    reason =
      "Synthetic host proof-harness judgment, not human approval. " <>
        if(ctx.variant == "seeded",
          do: "Deliberately passed to expose disagreement with the failing pinned check.",
          else: "Passed the bounded clean-case contract."
        )

    {:ok, _receipt} =
      Assurance.judge(
        @human,
        ctx.id,
        Map.merge(event(ctx.id <> "-judge", 2), %{
          "outcome" => "passed",
          "reason" => reason
        })
      )
  end

  defp controls(ctx, revise, verifier, check) do
    {:ok, projection} = Assurance.read(@human, ctx.id)
    duplicate = capture(ctx, verifier, "check", "native_check") == check

    stale =
      Assurance.capture(
        @human,
        ctx.id,
        Map.merge(event(ctx.id <> "-stale", 1), %{
          "predicate" => "check",
          "source" => %{"kind" => "native_check", "native_run_id" => verifier["id"]}
        })
      ) == {:error, :stale_generation}

    bounded =
      Assurance.revise(@human, ctx.id, %{
        revise
        | "request_id" => ctx.id <> "-third",
          "generation" => 2
      }) == {:error, :revision_round_bound}

    {:ok, replayed} =
      Native.launch(@human, ctx.id, %{
        "request_id" => verifier["id"],
        "profile_id" => ctx.id <> "-verify",
        "generation" => 2
      })

    restart = reopen(ctx, projection)

    %{
      "duplicate_capture_no_new_effect" => duplicate,
      "native_launch_replay_returns_original" => replayed == verifier,
      "stale_refused" => stale,
      "round_bound_refused" => bounded,
      "sqlite_store_process_reopen_preserves_native_evidence" => restart,
      "effect_authority_none" => projection["effect_authority"] == "none"
    }
  end

  defp reopen(ctx, expected) do
    path = Path.join(Path.dirname(ctx.base), "reopened-" <> Ecto.UUID.generate() <> ".db")
    rows = Repo.all(Assurance.Row)
    native = Repo.all(Native.Row)
    original = Repo.get_dynamic_repo()
    {:ok, first} = Repo.start_link(name: nil, database: path, pool_size: 1, log: false)
    Repo.put_dynamic_repo(first)

    try do
      Ecto.Migrator.run(Repo, Custode.Migrations.path(), :up, all: true, log: false)

      for row <- rows ++ native,
          do:
            Repo.insert!(
              Ecto.Changeset.change(
                row.__struct__.__struct__(),
                Map.drop(Map.from_struct(row), [:__meta__])
              )
            )

      GenServer.stop(first)
      {:ok, second} = Repo.start_link(name: nil, database: path, pool_size: 1, log: false)
      Repo.put_dynamic_repo(second)

      try do
        read_same = Assurance.read(@human, ctx.id) == {:ok, expected}
        verifier_id = ctx.id <> "-verify"

        {:ok, recaptured} =
          Assurance.capture(
            @human,
            ctx.id,
            Map.merge(event(ctx.id <> "-reopen-capture", 2), %{
              "predicate" => "check",
              "source" => %{"kind" => "native_check", "native_run_id" => verifier_id}
            })
          )

        read_same and recaptured["claim_class"] == "independently_reproduced"
      after
        GenServer.stop(second)
      end
    after
      Repo.put_dynamic_repo(original)
      if Process.alive?(first), do: GenServer.stop(first)
    end
  end

  defp native_summary(record),
    do:
      Map.take(
        record,
        ~w(id status profile profile_revision native_version stdin_mode observed produced_revision physical_settlement redelivery)
      )

  defp event(id, generation), do: %{"request_id" => id, "generation" => generation}
  defp save(root, report), do: private_write(Path.join(root, "result.json"), report)

  defp private_write(path, value) do
    File.write!(path, Jason.encode!(value, pretty: true))
    File.chmod!(path, 0o600)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git!(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _status} -> raise "fixture Git command failed: #{String.slice(output, 0, 1000)}"
    end
  end
end
