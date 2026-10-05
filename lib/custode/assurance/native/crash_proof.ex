defmodule Custode.Assurance.Native.CrashProof do
  @moduledoc "Explicit isolated crash controls; pending native reservations are never released."
  import Ecto.Query, only: [from: 2]
  alias Custode.{Assurance, Repo}
  alias Custode.Assurance.Native
  @human %{kind: :operator, id: "native-crash-proof-795"}
  @schema "custode.native-crash-case.v1"

  def worker(options) do
    guard!(options.root)
    context = prepare_case(options)
    configure(context)
    {:ok, _case} = Assurance.open(@human, context["open"])
    write(options.root, "case-state.json", context)
    {:ok, native} = Native.launch(@human, context["case_id"], context["launch"])
    write(options.root, "worker-result.json", native)
    native
  end

  def recover(options) do
    guard!(options.root)
    context = options.root |> Path.join("case-state.json") |> File.read!() |> Jason.decode!()
    validate_context!(context, options)
    before = Repo.all(Native.Row)
    [row] = before
    request = context["launch"]
    id = context["case_id"]

    validate_original!(row, context, options)

    configure(context)
    {:ok, replay} = Native.launch(@human, id, request)
    {:ok, _revision} = Assurance.revise(@human, id, revision(context))

    denied =
      Native.launch(@human, id, %{
        request
        | "request_id" => request["request_id"] <> "-redelivery",
          "generation" => 2
      })

    stale =
      Assurance.capture(@human, id, %{
        "request_id" => id <> "-stale",
        "generation" => 1,
        "predicate" => "check",
        "source" => %{"kind" => "native_check", "native_run_id" => row.id}
      })

    {:ok, decision} =
      Assurance.decide(@human, id, %{"request_id" => id <> "-decision", "generation" => 2})

    {:ok, projection} = Assurance.read(@human, id)
    controls = controls(before, replay, denied, stale, decision, projection)

    report = %{
      "schema" => "custode.native-crash-recovery.v1",
      "provider" => context["provider"],
      "synthetic" => context["synthetic"],
      "source_revision" => git!(File.cwd!(), ["rev-parse", "HEAD"]),
      "native_launches_in_recovery" => 0,
      "native_record" => row.record,
      "decision" => decision,
      "controls" => controls,
      "passed" => Enum.all?(Map.values(controls), & &1)
    }

    write(options.root, "recovery-result.json", report)
    report
  end

  defp validate_original!(row, context, options) do
    request = context["launch"]
    attempt = row.record["attempt"]
    open_matches = Enum.all?(~w(objective input artifact), &(attempt[&1] == context["open"][&1]))

    assignment_matches =
      Enum.all?(~w(criteria policy judge_id), &(attempt[&1] == context["assignment"][&1]))

    identity_matches =
      row.id == request["request_id"] and row.case_id == context["case_id"] and
        row.workspace == Path.join(options.root, "worker") and
        row.fingerprint == Assurance.digest({@human, context["case_id"], request})

    profile_matches =
      row.record["profile"]["configured_profile_digest"] == Assurance.digest(context["profile"])

    unless identity_matches and profile_matches and open_matches and assignment_matches,
      do: raise("original native reservation and frozen context binding required before recovery")
  end

  defp controls(before, replay, denied, stale, decision, projection) do
    %{
      "replay_preserves_original" => replay == hd(before).record,
      "workspace_redelivery_refused" => denied == {:error, :unsettled_workspace_already_claimed},
      "stale_generation_refused" => stale == {:error, :stale_generation},
      "native_records_unchanged" => Repo.all(Native.Row) == before,
      "one_original_native_record" => length(before) == 1,
      "missing_success_stays_missing" => decision["status"] == "escalated",
      "no_effect_authority" => projection["effect_authority"] == "none",
      "no_imported_late_evidence" =>
        Repo.aggregate(from(r in Assurance.Row, where: r.kind == "evidence"), :count) == 0
    }
  end

  defp revision(context) do
    context["open"]
    |> Map.take(~w(objective input artifact))
    |> Map.merge(%{"request_id" => context["case_id"] <> "-revision", "generation" => 1})
  end

  defp prepare_case(options) do
    root = options.root
    base = Path.join(root, "base")
    worker = Path.join(root, "worker")
    File.mkdir!(base)
    fixture = Application.app_dir(:custode, "priv/assurance_native")

    for name <- ~w(baseline.py verify.py),
        do: File.cp!(Path.join(fixture, name), Path.join(base, name))

    if options.provider == "codex",
      do:
        File.write!(
          Path.join(base, "submission.py"),
          "from baseline import baseline_add\ndef sum_pair(a,b):\n    return baseline_add(a,b)\n"
        )

    git!(base, ["init", "--initial-branch=main"])
    git!(base, ["config", "user.name", "joshrotenberg"])
    git!(base, ["config", "user.email", "joshrotenberg@gmail.com"])
    git!(base, ["add", "."])
    git!(base, ["-c", "commit.gpgsign=false", "commit", "-m", "test: fixed crash fixture"])
    head = git!(base, ["rev-parse", "HEAD"])
    git!(base, ["worktree", "add", "--detach", worker, head])
    id = "native-crash-" <> options.provider <> "-" <> Ecto.UUID.generate()

    owner =
      routine(
        id <> "-owner",
        "claude",
        if(options.provider == "claude", do: worker, else: base),
        root,
        options.claude_model
      )

    actor =
      if options.provider == "claude",
        do: owner,
        else: routine(id <> "-verifier", "codex", worker, root, options.codex_model)

    profile = profile(id, owner, actor, options)
    artifact = %{"kind" => "repository", "repository" => owner["repo"], "revision" => head}

    contract = %{
      "producer_file" => "submission.py",
      "producer_request" => "Create sum_pair(a,b) delegating to baseline_add(a,b).",
      "check" => "python3 -B verify.py",
      "check_file" => "verify.py",
      "check_sha256" => digest(File.read!(Path.join(base, "verify.py")))
    }

    %{
      "schema" => @schema,
      "host_pid" => System.pid(),
      "case_id" => id,
      "provider" => options.provider,
      "synthetic" => options.synthetic,
      "source_revision" => git!(File.cwd!(), ["rev-parse", "HEAD"]),
      "owner" => owner,
      "actor" => actor,
      "profile" => profile,
      "assignment" => assignment(id, owner["id"]),
      "launch" => %{
        "request_id" => id <> "-launch",
        "profile_id" => profile["id"],
        "generation" => 1
      },
      "open" => %{
        "case_id" => id,
        "assignment_id" => id,
        "objective" => "Retain interrupted native work without unsafe replay or acceptance.",
        "input" => Jason.encode!(contract),
        "artifact" => artifact
      }
    }
  end

  defp routine(id, provider, directory, root, model) do
    workspace = Path.join(root, id <> "-memory")
    File.mkdir!(workspace)

    %{
      "id" => id,
      "provider" => provider,
      "model" => model,
      "effort" => "low",
      "working_dir" => directory,
      "workspace" => workspace,
      "repo" => "fixture/native-crash",
      "cron" => "@daily",
      "prompt" => "Explicit isolated crash proof only."
    }
  end

  defp profile(id, owner, actor, options) do
    binary =
      if options.synthetic,
        do: Path.expand("test/fixtures/assurance_crash_cli.py"),
        else: System.find_executable(options.provider)

    unless is_binary(binary), do: raise("native binary unavailable")

    %{
      "id" => id <> "-profile",
      "owner_id" => owner["id"],
      "actor_id" => actor["id"],
      "role" => if(options.provider == "claude", do: "producer", else: "verifier"),
      "provider" => options.provider,
      "binary" => binary,
      "working_dir" => actor["working_dir"],
      "model" => actor["model"],
      "effort" => "low",
      "timeout_ms" => 60_000,
      "max_budget_usd" => 0.5
    }
  end

  defp assignment(id, owner) do
    %{
      "id" => id,
      "owner_id" => owner,
      "judge_id" => @human.id,
      "max_rounds" => 2,
      "criteria" => ["Interrupted work is never accepted without pinned independent evidence."],
      "policy" => %{
        "predicates" => [
          %{
            "name" => "check",
            "sources" => ["native_check"],
            "classes" => ["independently_reproduced"],
            "independent" => true
          }
        ]
      }
    }
  end

  defp configure(context) do
    actors =
      [context["owner"], context["actor"]]
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&atom_routine/1)

    Application.put_env(:custode, :routines, actors)
    Application.put_env(:custode, :assurance_assignments, [context["assignment"]])
    Application.put_env(:custode, :assurance_native_profiles, [context["profile"]])
    Application.put_env(:custode, :assurance_native_enabled, true)
  end

  defp atom_routine(actor) do
    keys = ~w(id provider model effort working_dir workspace repo cron prompt)a

    Map.new(keys, fn key ->
      {key,
       if(key == :provider,
         do: provider_atom(actor["provider"]),
         else: actor[Atom.to_string(key)]
       )}
    end)
  end

  defp provider_atom("claude"), do: :claude
  defp provider_atom("codex"), do: :codex

  defp validate_context!(context, options) do
    unless context["schema"] == @schema and context["provider"] == options.provider and
             context["synthetic"] == options.synthetic and
             context["profile"]["working_dir"] == Path.join(options.root, "worker"),
           do: raise("recorded crash context mismatch")
  end

  defp guard!(root) do
    unless Mix.env() == :test and System.get_env("CUSTODE_NATIVE_CRASH_PROOF") == "1" and
             Application.get_env(:custode, :assurance_crash_proof_root) == root and
             Path.expand(Repo.config()[:database]) == Path.join(root, "operations.db") and
             Application.get_env(:custode, :oban_queues) == [] and
             Application.get_env(:custode, :scheduler_autostart) == false,
           do: raise("guarded isolated crash task required")
  end

  defp git!(directory, argv) do
    case System.cmd("git", argv, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _error -> raise("fixture Git operation failed")
    end
  end

  defp write(root, name, value) do
    path = Path.join(root, name)
    pending = path <> ".pending"
    File.write!(pending, Jason.encode!(value, pretty: true))
    File.chmod!(pending, 0o600)
    File.rename!(pending, path)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
