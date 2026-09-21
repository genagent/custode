defmodule Custode.Verification.RunnerTest do
  use ExUnit.Case, async: true

  alias Custode.Verification.{CommandSpec, Recipe, Recipes, Runner}

  test "a reviewed argv command captures stdout and stderr separately" do
    spec =
      spec!(
        argv: ["/bin/sh", "-c", "printf stdout; printf stderr >&2"],
        shell: true,
        risk: "internal_write"
      )

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "pass"
    assert result["stdout_tail"] == "stdout"
    assert result["stderr_tail"] == "stderr"
    assert result["exit_code"] == 0
  end

  test "nonzero exit is a structured test failure" do
    spec = spec!(name: "failure", category: "test", argv: ["/usr/bin/false"])

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "test_failure"
    assert result["exit_code"] != 0
  end

  test "output limits are explicit policy refusals with truncation metadata" do
    spec =
      spec!(
        name: "output_limit",
        argv: ["/usr/bin/yes", "bounded"],
        output_limit_bytes: 1_024,
        tail_bytes: 128,
        timeout_ms: 5_000
      )

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "policy_refusal"
    assert result["reason"] =~ "output_limit_exceeded"
    assert result["stdout_truncated"]
    assert result["stdout_bytes"] > result["output_limit_bytes"]
    assert byte_size(result["stdout_tail"]) <= 128
  end

  test "timeout kills descendants in the owned process tree" do
    fixture = process_tree_fixture(:wait)

    spec =
      spec!(
        name: "timeout",
        argv: ["/bin/sh", fixture.script, fixture.root],
        timeout_ms: 100
      )

    task = Task.async(fn -> Runner.run(spec, File.cwd!()) end)
    assert eventually(fn -> File.exists?(fixture.ready) end)

    :erlang.suspend_process(task.pid)
    Process.sleep(150)
    assert File.exists?(fixture.side_effect)
    :erlang.resume_process(task.pid)

    assert {:ok, result} = Task.await(task, 5_000)
    assert result["status"] == "timeout"
    assert_processes_dead(fixture)
  end

  test "cancellation kills descendants and is distinct from timeout" do
    fixture = process_tree_fixture(:wait)

    spec =
      spec!(
        name: "cancel",
        argv: ["/bin/sh", fixture.script, fixture.root],
        timeout_ms: 5_000
      )

    task =
      Task.async(fn ->
        Runner.run(spec, File.cwd!(), cancelled?: fn -> File.exists?(fixture.cancel) end)
      end)

    assert eventually(fn -> File.exists?(fixture.ready) end)
    File.touch!(fixture.cancel)

    assert {:ok, result} = Task.await(task, 2_000)
    assert result["status"] == "cancellation"
    assert_processes_dead(fixture)
  end

  test "a normal parent exit cleans up observed descendants before returning" do
    fixture = process_tree_fixture(:release)

    spec =
      spec!(
        name: "normal_exit",
        argv: ["/bin/sh", fixture.script, fixture.root],
        timeout_ms: 5_000
      )

    task = Task.async(fn -> Runner.run(spec, File.cwd!()) end)
    assert eventually(fn -> File.exists?(fixture.ready) end)
    assert eventually(fn -> observed_descendant?(fixture) end)
    File.touch!(fixture.release)

    assert {:ok, result} = Task.await(task, 2_000)
    assert result["status"] == "pass"
    assert_processes_dead(fixture)
  end

  test "a terminated command exit is recorded as cancellation" do
    spec =
      spec!(
        name: "terminated",
        argv: ["/bin/sh", "-c", "exit 143"],
        shell: true,
        risk: "internal_write"
      )

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "cancellation"
    assert result["exit_code"] == 143
  end

  test "missing executables are infrastructure errors" do
    spec = spec!(name: "missing", argv: ["custode-command-that-does-not-exist"])

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "infrastructure_error"
    assert result["reason"] =~ "executable_not_found"
  end

  test "cwd escape, environment injection, and unreviewed shell strings are refused" do
    assert {:error, :working_directory_escape_refused} =
             CommandSpec.new(spec_attrs(working_directory: "../outside"))

    assert {:error, :environment_injection_refused} =
             CommandSpec.new(
               spec_attrs(
                 environment_allowlist: ["PATH"],
                 environment: %{"SECRET" => "not-reviewed"}
               )
             )

    assert {:error, :shell_interpretation_requires_explicit_risk} =
             CommandSpec.new(
               spec_attrs(
                 argv: ["/bin/sh", "-c", "printf unsafe"],
                 shell: false
               )
             )

    assert {:error, :unreviewed_command_refused} =
             CommandSpec.new(
               spec_attrs(
                 argv: ["/bin/sh", "-c", "printf unsafe"],
                 shell: true,
                 risk: "internal_write",
                 reviewed: false
               )
             )
  end

  test "a relative cwd symlink cannot escape the owned workspace" do
    root = Path.join(System.tmp_dir!(), "verification-cwd-#{Ecto.UUID.generate()}")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(workspace, "escape"))

    spec = spec!(working_directory: "escape")
    assert {:ok, result} = Runner.run(spec, workspace)
    assert result["status"] == "policy_refusal"
    assert result["reason"] =~ "working_directory_refused"

    File.rm_rf!(root)
  end

  test "expected exit policy can explicitly accept a nonzero code" do
    spec =
      spec!(
        name: "expected_nonzero",
        argv: ["/bin/sh", "-c", "exit 7"],
        shell: true,
        risk: "internal_write",
        expected_exit_codes: [7]
      )

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "pass"
    assert result["exit_code"] == 7
  end

  test "recipes require unique named format, test, analysis, and repository results" do
    assert {:ok, recipe} = Recipes.elixir()

    assert Enum.map(recipe.commands, & &1.category) |> Enum.uniq() |> Enum.sort() ==
             ~w(format repository static_analysis test)

    rendered = Recipe.render(recipe)
    assert {:ok, restored} = Recipe.new(rendered)
    assert restored.digest == recipe.digest

    [first | rest] = rendered["commands"]

    assert {:error, :duplicate_verification_command} =
             Recipe.new(%{
               rendered
               | "commands" => [first, first | rest]
             })
  end

  defp spec!(overrides) do
    assert {:ok, spec} = CommandSpec.new(spec_attrs(overrides))
    spec
  end

  defp spec_attrs(overrides) do
    defaults = [
      name: "command",
      category: "format",
      argv: ["/usr/bin/true"],
      working_directory: ".",
      environment_allowlist: ["PATH"],
      environment: %{},
      timeout_ms: 1_000,
      output_limit_bytes: 16_384,
      tail_bytes: 1_024,
      expected_exit_codes: [0],
      risk: "read",
      shell: false,
      reviewed: true
    ]

    Keyword.merge(defaults, overrides)
  end

  defp process_tree_fixture(parent_action) do
    root = Path.join(System.tmp_dir!(), "verification-tree-#{Ecto.UUID.generate()}")
    script = Path.join(root, "spawn.sh")
    File.mkdir_p!(root)

    parent_command =
      case parent_action do
        :wait -> "sleep 5"
        :release -> ~s(while [ ! -f "$1/release" ]; do sleep 0.01; done; sleep 0.1)
      end

    File.write!(
      script,
      """
      #!/bin/sh
      printf '%s' "$$" > "$1/parent_pid"
      /bin/sh -c '
        printf "%s" "$$" > "$1/child_pid"
        trap "exit 0" TERM INT
        sleep 30 &
        printf "%s" "$!" > "$1/grandchild_pid"
        printf completed > "$1/side_effect"
        printf ready > "$1/ready"
        wait
      ' child "$1" &
      #{parent_command}
      """
    )

    fixture = %{
      root: root,
      script: script,
      ready: Path.join(root, "ready"),
      side_effect: Path.join(root, "side_effect"),
      cancel: Path.join(root, "cancel"),
      release: Path.join(root, "release")
    }

    on_exit(fn ->
      for pid <- fixture_pids(fixture), process_alive?(pid) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      File.rm_rf!(root)
    end)

    fixture
  end

  defp assert_processes_dead(fixture) do
    pids = fixture_pids(fixture)
    assert length(pids) == 3
    assert eventually(fn -> Enum.all?(pids, &(not process_alive?(&1))) end)
  end

  defp observed_descendant?(fixture) do
    case fixture_pids(fixture) do
      [parent, child | _rest] -> child in descendants_of(parent)
      _incomplete -> false
    end
  end

  defp fixture_pids(fixture) do
    ["parent_pid", "child_pid", "grandchild_pid"]
    |> Enum.map(&File.read(Path.join(fixture.root, &1)))
    |> Enum.flat_map(fn
      {:ok, pid} ->
        case Integer.parse(pid) do
          {value, ""} -> [value]
          _invalid -> []
        end

      {:error, _reason} ->
        []
    end)
  end

  defp descendants_of(parent) do
    case System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&direct_child(&1, parent))

      {_output, _status} ->
        []
    end
  end

  defp direct_child(line, parent) do
    case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {^parent, ""}] -> [pid]
      _other -> []
    end
  end

  defp process_alive?(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="], stderr_to_stdout: true) do
      {state, 0} ->
        state = String.trim(state)
        state != "" and not String.starts_with?(state, "Z")

      {_output, _status} ->
        false
    end
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
