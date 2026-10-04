defmodule Custode.Assurance.Native do
  @moduledoc """
  Opt-in bounded native proof recorder. It observes its own configured launches;
  there is no API for importing a provider label, trust class or command result.
  A pending launch is never automatically redelivered after owner loss.
  """
  import Ecto.Query, only: [from: 2]
  alias Custode.{AgentHandoff, Assurance, Repo, Routine}
  alias Custode.Assurance.Native.Events
  alias Custode.Verification.Runner

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :string, autogenerate: false}
    schema "assurance_native_runs" do
      field(:case_id, :string)
      field(:workspace, :string)
      field(:fingerprint, :string)
      field(:status, :string)
      field(:record, :map)
    end
  end

  @check_diagnostic "git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead"

  @doc "Launch one configured profile once against an exact current assurance generation."
  def launch(%{kind: :operator, id: actor} = human, case_id, request)
      when is_binary(actor) and actor != "" do
    with true <- Application.get_env(:custode, :assurance_native_enabled, false),
         :ok <- request_shape(request) do
      fingerprint = Assurance.digest({human, case_id, request})

      case Repo.get(Row, request["request_id"]) do
        %Row{fingerprint: ^fingerprint} = row -> {:ok, row.record}
        %Row{} -> {:error, :idempotency_conflict}
        nil -> fresh_launch(human, case_id, request, fingerprint)
      end
    else
      false -> {:error, :native_proof_disabled}
      error -> error
    end
  end

  def launch(_actor, _case, _request), do: {:error, :operator_required}

  defp fresh_launch(human, case_id, request, fingerprint) do
    with {:ok, projection} <- Assurance.read(human, case_id),
         true <- "current_policy" not in projection["evaluation"]["missing"],
         %Assurance.Row{} = row <- Repo.get(Assurance.Row, "case:" <> case_id),
         attempt = row.record["current"],
         true <- attempt["generation"] == request["generation"],
         {:ok, profile} <- profile(request["profile_id"], row.record),
         {:ok, contract} <- contract(attempt),
         :ok <- owner_current(row.record),
         {:ok, head} <- git(profile, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == attempt["artifact"]["revision"],
         {:ok, ""} <- git(profile, ["status", "--porcelain", "--untracked-files=all"]),
         {:ok, version} <- version(profile),
         {:ok, admitted} <-
           admit(row.record, attempt, profile, contract, version, request, fingerprint) do
      if admitted["status"] == "running" and admitted["launch_token"] == request["request_id"] do
        execute(admitted, profile, contract)
      else
        {:ok, admitted}
      end
    else
      false -> {:error, :stale_generation_or_artifact}
      nil -> {:error, :unknown_case}
      error -> error
    end
  end

  defp admit(record, attempt, profile, contract, version, request, fingerprint) do
    Repo.transaction(
      fn ->
        current = Repo.get!(Assurance.Row, "case:" <> record["case_id"]).record["current"]
        count = Repo.aggregate(from(r in Row, where: r.case_id == ^record["case_id"]), :count)

        case Repo.get(Row, request["request_id"]) do
          %Row{fingerprint: ^fingerprint} = row ->
            Map.put(row.record, "launch_token", nil)

          %Row{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            insert_launch!(
              record,
              attempt,
              profile,
              contract,
              version,
              request,
              fingerprint,
              {current, count}
            )
        end
      end,
      mode: :immediate
    )
  end

  defp insert_launch!(
         record,
         attempt,
         profile,
         contract,
         version,
         request,
         fingerprint,
         {current, count}
       ) do
    if current["case_revision"] != attempt["case_revision"],
      do: Repo.rollback(:stale_generation)

    if count >= 4, do: Repo.rollback(:native_call_bound)

    if Repo.get_by(Row, workspace: profile["working_dir"]),
      do: Repo.rollback(:unsettled_workspace_already_claimed)

    if not admission_current?(record, profile), do: Repo.rollback(:native_admission_changed)

    launch = %{
      "id" => request["request_id"],
      "case_id" => record["case_id"],
      "status" => "running",
      "launch_token" => request["request_id"],
      "owner_id" => record["owner_id"],
      "profile" => profile,
      "profile_revision" => Assurance.digest({profile, version}),
      "native_version" => version,
      "stdin_mode" => "null",
      "before_check_sha256" => file_digest(profile, contract),
      "attempt" => attempt,
      "contract" => contract,
      "check_command" =>
        "cd " <> shell_quote(profile["working_dir"]) <> " && " <> contract["check"],
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "physical_settlement" => %{
        "all_descendants_attestation" => "missing",
        "native_exit_observed" => false
      },
      "redelivery" => "refused_without_all_descendants_attestation"
    }

    Repo.insert!(%Row{
      id: request["request_id"],
      case_id: record["case_id"],
      workspace: profile["working_dir"],
      fingerprint: fingerprint,
      status: "running",
      record: launch
    })

    launch
  end

  defp execute(launch, profile, contract) do
    argv = argv(profile, prompt(launch, contract))

    spec = %{
      name: "native_assurance",
      category: "test",
      argv: argv,
      working_directory: ".",
      environment_allowlist:
        ~w(PATH HOME USER TMPDIR LANG LC_ALL ANTHROPIC_API_KEY OPENAI_API_KEY),
      timeout_ms: profile["timeout_ms"],
      output_limit_bytes: 512_000,
      tail_bytes: 32_000,
      expected_exit_codes: [0],
      risk: "internal_write",
      reviewed: true
    }

    {:ok, result} = Runner.run(spec, profile["working_dir"], stdin: :null)
    raw = Base.decode64!(get_in(result, ["output", "stdout", "captured_base64"]))
    observed = Events.observe(profile["provider"], raw)
    current = Repo.get!(Assurance.Row, "case:" <> launch["case_id"]).record["current"]

    produced =
      if current["case_revision"] == launch["attempt"]["case_revision"],
        do: produced_revision(profile, contract, result, observed)

    after_head = git(profile, ["rev-parse", "HEAD"])
    clean = git(profile, ["status", "--porcelain", "--untracked-files=all"]) == {:ok, ""}

    finalized =
      launch
      |> Map.delete("launch_token")
      |> Map.merge(%{
        "argv" => argv,
        "runner" => result,
        "observed" => observed,
        "produced_revision" => produced,
        "after_check_sha256" => file_digest(profile, contract),
        "after_head" => command_value(after_head),
        "after_clean" => clean,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "physical_settlement" => %{
          "native_exit_observed" => is_integer(result["exit_code"]),
          "all_descendants_attestation" => "missing",
          "observed_descendant_cleanup" => result["runner_version"]
        },
        "status" =>
          if(
            result["status"] == "pass" and observed["terminal_observed"] and
              observed["protocol_errors"] == [],
            do: "completed",
            else: "incomplete"
          )
      })

    Repo.transaction(
      fn ->
        row = Repo.get!(Row, launch["id"])
        current = Repo.get!(Assurance.Row, "case:" <> launch["case_id"]).record["current"]

        finalized =
          if current["case_revision"] == launch["attempt"]["case_revision"],
            do: finalized,
            else: Map.put(finalized, "status", "stale")

        Repo.update!(Ecto.Changeset.change(row, status: finalized["status"], record: finalized))
        finalized
      end,
      mode: :immediate
    )
  end

  @doc "Read an observed producer identity only for its own case and recorder-created artifact commit."
  def producer(owner, id, case_id, frozen) when is_binary(id) do
    case Repo.get(Row, id) do
      %Row{status: "completed", case_id: ^case_id, record: record} ->
        same_inputs =
          Enum.all?(
            ~w(objective_revision input_revision criteria_revision policy_digest),
            &(record["attempt"][&1] == frozen[&1])
          )

        if record["owner_id"] == owner and record["profile"]["role"] == "producer" and same_inputs and
             record["produced_revision"] == frozen["artifact"]["revision"],
           do: execution(record)

      _other ->
        nil
    end
  end

  def producer(_owner, _id, _case, _frozen), do: nil

  @doc "Observe a completed native source by reference, never by caller payload."
  def evidence(record, kind, id) do
    case_id = record["case_id"]

    case Repo.get(Row, id) do
      %Row{case_id: ^case_id, record: native} ->
        current = record["current"]

        exact =
          native["status"] == "completed" and native["profile"]["role"] == "verifier" and
            native["attempt"]["case_revision"] == current["case_revision"] and
            native["after_clean"] and
            native["after_head"] == current["artifact"]["revision"]

        observe_source(kind, native, current, exact)

      _other ->
        {:error, :native_source_unavailable}
    end
  end

  defp observe_source("native_check", native, current, exact) do
    commands =
      (get_in(native, ["observed", "commands"]) || [])
      |> Enum.uniq()
      |> Enum.filter(&check_command?(&1, native["check_command"]))

    command = if length(commands) == 1, do: hd(commands)

    bound =
      Enum.all?([
        exact,
        not is_nil(execution(native)),
        not is_nil(command),
        native["before_check_sha256"] == native["contract"]["check_sha256"],
        native["after_check_sha256"] == native["contract"]["check_sha256"],
        check_output?(command, native, current)
      ])

    {:ok,
     source(
       native,
       "native_check",
       if(independent_receipt?(bound, native, current),
         do: "independently_reproduced",
         else: "host_observed"
       ),
       if(bound,
         do: if(command["exit_code"] == 0, do: "passed", else: "failed"),
         else: "unknown"
       ),
       if(bound, do: [], else: ["exact_native_command_case_artifact_config_session"]),
       command,
       current
     )}
  end

  defp observe_source("native_opinion", native, current, exact) do
    opinion = get_in(native, ["observed", "opinion"])

    bound = exact and not is_nil(execution(native)) and bound_opinion?(opinion, current)

    outcome =
      if bound,
        do: if(opinion["verdict"] == "clean", do: "passed", else: "failed"),
        else: "unknown"

    {:ok,
     source(
       native,
       "native_opinion",
       if(independent_receipt?(bound, native, current),
         do: "independent_opinion",
         else: "self_reported"
       ),
       outcome,
       if(bound, do: [], else: ["exact_native_opinion_case_artifact_config_session"]),
       opinion,
       current
     )}
  end

  defp bound_opinion?(%{} = opinion, current) do
    Enum.all?([
      opinion["artifact_revision"] == current["artifact"]["revision"],
      opinion["case_revision"] == current["case_revision"],
      opinion["verdict"] in ~w(clean findings),
      is_list(opinion["findings"])
    ])
  end

  defp bound_opinion?(_opinion, _current), do: false

  defp independent_receipt?(bound, native, current), do: bound and independent?(native, current)

  defp check_output?(nil, _native, _current), do: false

  defp check_output?(command, native, current) do
    with output when is_binary(output) <- command["aggregated_output"],
         {:ok, %{} = result} <- check_frame(output) do
      Enum.all?([
        result["artifact_revision"] == current["artifact"]["revision"],
        result["check_sha256"] == native["contract"]["check_sha256"],
        is_list(result["checks"]),
        result["passed"] == (command["exit_code"] == 0),
        check_rows?(result)
      ])
    else
      _other -> false
    end
  end

  defp check_frame(output) do
    case String.split(String.trim(output), "\n") do
      [frame] -> Jason.decode(frame)
      [@check_diagnostic, frame] -> Jason.decode(frame)
      _other -> {:error, :ambiguous_or_unrecognized_native_check_output}
    end
  end

  defp diagnostics(%{"aggregated_output" => output}) when is_binary(output) do
    if String.starts_with?(output, @check_diagnostic <> "\n"), do: [@check_diagnostic], else: []
  end

  defp diagnostics(_payload), do: []

  defp check_rows?(%{"passed" => true, "failure" => nil, "checks" => checks})
       when is_list(checks) do
    expected =
      for pair <- [[0, 0], [1, 2], [-2, 1], [-4, -3], [123, 99]],
          name <- ~w(baseline_add sum_pair),
          do: %{
            "check" => name,
            "input" => pair,
            "expected" => Enum.sum(pair),
            "observed" => Enum.sum(pair),
            "passed" => true
          }

    checks == expected
  end

  defp check_rows?(%{"passed" => false, "checks" => [], "failure" => failure})
       when is_binary(failure), do: true

  defp check_rows?(%{"passed" => false, "checks" => checks, "failure" => nil})
       when is_list(checks) do
    expected =
      for pair <- [[0, 0], [1, 2], [-2, 1], [-4, -3], [123, 99]],
          name <- ~w(baseline_add sum_pair),
          do: {name, pair, Enum.sum(pair)}

    length(checks) == length(expected) and
      Enum.all?(Enum.zip(checks, expected), &failure_row?/1) and
      Enum.any?(checks, &(&1["passed"] == false))
  end

  defp check_rows?(_other), do: false

  defp failure_row?({%{} = row, {name, pair, sum}}) do
    observed = row["observed"]

    Enum.all?([
      row["check"] == name,
      row["input"] == pair,
      row["expected"] == sum,
      is_integer(observed),
      row["passed"] == (observed == sum)
    ])
  end

  defp failure_row?(_other), do: false

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp independent?(native, current) do
    producer = current["producer"]
    verifier = execution(native)

    is_map(producer) and is_map(verifier) and
      Enum.all?(
        ~w(actor provider run_id revision),
        &(is_binary(producer[&1]) and producer[&1] != "")
      ) and
      Enum.all?(~w(actor provider run_id), &(producer[&1] != verifier[&1]))
  end

  defp source(native, kind, class, outcome, missing, payload, _current) do
    %{
      "kind" => kind,
      "claim_class" => class,
      "outcome" => outcome,
      "execution" => execution(native),
      "missing_bindings" => missing,
      "limits" => [
        "all_descendants_attestation_missing",
        "unobserved_managed_native_settings",
        "harness_judgment_is_not_human_approval"
      ],
      "source" => %{
        "native_run_id" => native["id"],
        "stream_sha256" => native["observed"]["stream_sha256"]
      },
      "snapshot" => %{
        "native_run_id" => native["id"],
        "native_version" => native["native_version"],
        "stdin_mode" => native["stdin_mode"],
        "profile_revision" => native["profile_revision"],
        "physical_settlement" => native["physical_settlement"],
        "observation_digest" => Assurance.digest(payload),
        "observation" => compact_observation(kind, payload),
        "diagnostics" => diagnostics(payload)
      }
    }
  end

  defp compact_observation("native_check", %{} = command),
    do: Map.take(command, ~w(id command cwd exit_code status))

  defp compact_observation("native_opinion", %{} = opinion),
    do: Map.take(opinion, ~w(case_revision artifact_revision verdict))

  defp compact_observation(_kind, _payload), do: nil

  defp execution(native) do
    session = get_in(native, ["observed", "session_id"])

    if is_binary(session) and session != "" and native["status"] == "completed" and
         native["observed"]["protocol_errors"] == [] do
      %{
        "actor" => native["profile"]["actor_id"],
        "provider" => native["profile"]["provider"],
        "run_id" => native["id"] <> ":" <> session,
        "revision" => native["profile_revision"],
        "native_session_id" => session,
        "requested_model" => native["profile"]["model"],
        "requested_effort" => native["profile"]["effort"],
        "observed_effort" => nil,
        "observed_model" => native["observed"]["observed_model"]
      }
    end
  end

  defp check_command?(command, expected) do
    exit = command["exit_code"]

    completed =
      is_integer(exit) and
        (command["status"] == "completed" or (command["status"] == "failed" and exit != 0))

    completed and exact_command?(command["command"], expected)
  end

  defp exact_command?(actual, expected) when is_binary(actual) do
    actual == expected or
      OptionParser.split(actual) in [
        ["/bin/zsh", "-lc", expected],
        ["/bin/bash", "-lc", expected],
        ["/bin/sh", "-lc", expected]
      ]
  rescue
    ArgumentError -> false
  end

  defp exact_command?(_actual, _expected), do: false

  defp file_digest(profile, contract) do
    Path.join(profile["working_dir"], contract["check_file"])
    |> File.read()
    |> case do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      _error -> nil
    end
  end

  defp produced_revision(%{"role" => "producer"} = profile, contract, result, observed) do
    if result["status"] == "pass" and observed["terminal_observed"] and
         observed["protocol_errors"] == [] do
      file = contract["producer_file"]

      with {:ok, status} <- git(profile, ["status", "--porcelain", "--untracked-files=all"]),
           true <- String.trim(status) in ["?? " <> file, "M " <> file],
           {:ok, _added} <- git(profile, ["add", "--", file]),
           {:ok, _committed} <-
             git(profile, [
               "-c",
               "commit.gpgsign=false",
               "commit",
               "-m",
               "test: retain native producer artifact"
             ]),
           {:ok, head} <- git(profile, ["rev-parse", "HEAD"]) do
        String.trim(head)
      else
        _failure -> nil
      end
    end
  end

  defp produced_revision(_profile, _contract, _result, _observed), do: nil

  defp prompt(launch, contract) do
    attempt = launch["attempt"]

    base =
      "Frozen objective: #{attempt["objective"]}\nAcceptance criteria: #{Jason.encode!(attempt["criteria"])}\n"

    if launch["profile"]["role"] == "producer" do
      base <>
        contract["producer_request"] <>
        "\nEdit only #{contract["producer_file"]}. Do not edit baseline or checks. Do not commit."
    else
      base <>
        "Cold verification. Ignore any producer conclusion. Run this exact command once: #{launch["check_command"]}.\n" <>
        "Return only JSON with case_revision=#{attempt["case_revision"]}, artifact_revision=#{attempt["artifact"]["revision"]}, " <>
        "verdict (clean or findings), and findings array. Report observed failures; never invent a tool exit."
    end
  end

  defp argv(%{"provider" => "claude"} = profile, prompt) do
    [
      profile["binary"],
      "--print",
      "--verbose",
      "--output-format",
      "stream-json",
      "--model",
      profile["model"],
      "--effort",
      profile["effort"] || "low",
      "--max-budget-usd",
      to_string(profile["max_budget_usd"]),
      "--settings",
      "{\"disableAllHooks\":true}",
      "--safe-mode",
      "--restricted",
      "--no-session-persistence",
      "--strict-mcp-config",
      "--mcp-config",
      "{\"mcpServers\":{}}",
      "--permission-mode",
      "acceptEdits",
      "--tools",
      "Read,Write",
      "--allowedTools",
      "Read,Write",
      "--",
      prompt
    ]
  end

  defp argv(%{"provider" => "codex"} = profile, prompt) do
    [
      profile["binary"],
      "exec",
      "--ignore-user-config",
      "--ignore-rules",
      "--model",
      profile["model"],
      "-c",
      "model_reasoning_effort=\"#{profile["effort"]}\"",
      "--sandbox",
      "read-only",
      "--ephemeral",
      "--json",
      prompt
    ]
  end

  defp profile(id, record) do
    selected =
      Application.get_env(:custode, :assurance_native_profiles, [])
      |> Enum.find(&(&1["id"] == id))

    with true <- valid_profile?(selected, record),
         {:ok, captured} <- AgentHandoff.authorization_routine(selected["actor_id"]),
         actor when not is_nil(actor) <- Routine.get(selected["actor_id"]),
         {:ok, physical} <- physical(selected["working_dir"]),
         {:ok, actor_physical} <- physical(actor.working_dir),
         true <- physical == actor_physical,
         true <- actor.provider |> to_string() == selected["provider"],
         true <- actor.model == selected["model"],
         true <- actor_effort?(actor, selected),
         true <- captured.execution_revision == Routine.execution_revision(actor) do
      profile =
        Map.take(
          selected,
          ~w(id owner_id actor_id role provider binary working_dir model effort timeout_ms max_budget_usd)
        )

      {:ok,
       profile
       |> Map.put("working_dir", physical)
       |> Map.put("actor_revision", captured.execution_revision)
       |> Map.put("configured_profile_digest", Assurance.digest(selected))}
    else
      _other -> {:error, :native_profile_unavailable}
    end
  end

  defp actor_effort?(actor, profile), do: to_string(actor.effort) == profile["effort"]

  defp admission_current?(record, profile) do
    selected =
      Application.get_env(:custode, :assurance_native_profiles, [])
      |> Enum.find(&(&1["id"] == profile["id"]))

    owner = Routine.get(record["owner_id"])
    actor = Routine.get(profile["actor_id"])

    {:ok, projection} =
      Assurance.read(%{kind: :operator, id: "native-admission-recorder"}, record["case_id"])

    Enum.all?([
      not is_nil(owner),
      not is_nil(actor),
      actor_revision(actor) == profile["actor_revision"],
      actor_revision(owner) == record["current"]["owner_revision"],
      Assurance.digest(selected) == profile["configured_profile_digest"],
      "current_policy" not in projection["evaluation"]["missing"]
    ])
  end

  defp actor_revision(nil), do: nil
  defp actor_revision(actor), do: Routine.execution_revision(actor)

  defp physical(directory) do
    case System.cmd("pwd", ["-P"], cd: directory) do
      {output, 0} -> {:ok, String.trim(output)}
      _other -> {:error, :workspace_unavailable}
    end
  rescue
    _error -> {:error, :workspace_unavailable}
  end

  defp valid_profile?(%{} = profile, record) do
    Enum.all?([
      profile["owner_id"] == record["owner_id"],
      Enum.all?(
        ~w(binary actor_id working_dir model),
        &(is_binary(profile[&1]) and profile[&1] != "")
      ),
      profile["timeout_ms"] in 1..180_000,
      role_allowed?(profile, record)
    ])
  end

  defp valid_profile?(_profile, _record), do: false

  defp role_allowed?(%{"role" => "producer", "provider" => "claude"} = profile, record),
    do:
      profile["actor_id"] == record["owner_id"] and profile["max_budget_usd"] in [0.25, 0.5, 1.0]

  defp role_allowed?(%{"role" => "verifier", "provider" => "codex"} = profile, record),
    do: profile["actor_id"] != record["owner_id"] and profile["effort"] == "low"

  defp role_allowed?(_profile, _record), do: false

  defp contract(attempt) do
    with %{"kind" => "repository"} <- attempt["artifact"],
         {:ok, %{} = input} <- Jason.decode(attempt["input"]),
         true <-
           Enum.all?(
             ~w(producer_file producer_request check check_file check_sha256),
             &(is_binary(input[&1]) and input[&1] != "")
           ),
         true <-
           Enum.all?(
             [input["producer_file"], input["check_file"]],
             &(Path.type(&1) == :relative and ".." not in Path.split(&1))
           ) do
      {:ok, input}
    else
      _other -> {:error, :native_contract_unavailable}
    end
  end

  defp owner_current(record) do
    with {:ok, captured} <- AgentHandoff.authorization_routine(record["owner_id"]),
         owner when not is_nil(owner) <- Routine.get(record["owner_id"]),
         true <- captured.execution_revision == Routine.execution_revision(owner),
         true <- captured.execution_revision == record["current"]["owner_revision"] do
      :ok
    else
      _other -> {:error, :owner_scope_unavailable}
    end
  end

  defp version(profile) do
    spec = %{
      name: "native_version",
      category: "test",
      argv: [profile["binary"], "--version"],
      working_directory: ".",
      environment_allowlist: ~w(PATH HOME TMPDIR),
      timeout_ms: 5_000,
      output_limit_bytes: 4096,
      tail_bytes: 4096,
      risk: "read",
      reviewed: true
    }

    case Runner.run(spec, profile["working_dir"], stdin: :null) do
      {:ok, %{"status" => "pass", "stdout_tail" => output}} -> {:ok, String.trim(output)}
      _failure -> {:error, :native_version_unavailable}
    end
  end

  defp git(profile, argv) do
    case System.cmd("git", argv, cd: profile["working_dir"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  rescue
    _error -> {:error, :workspace_unavailable}
  end

  defp command_value({:ok, output}), do: String.trim(output)
  defp command_value(_error), do: nil

  defp request_shape(
         %{"request_id" => id, "profile_id" => profile, "generation" => generation} = request
       ) do
    if map_size(request) == 3 and is_binary(id) and byte_size(id) in 1..160 and is_binary(profile) and
         is_integer(generation) and generation in 1..16,
       do: :ok,
       else: {:error, :invalid_arguments}
  end

  defp request_shape(_request), do: {:error, :invalid_arguments}
end
