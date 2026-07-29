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
    root = Path.join(System.tmp_dir!(), "verification-tree-#{Ecto.UUID.generate()}")
    script = Path.join(root, "spawn.sh")
    marker = Path.join(root, "orphan")
    File.mkdir_p!(root)

    File.write!(
      script,
      """
      #!/bin/sh
      (sleep 0.3; printf orphan > "$1") &
      sleep 5
      """
    )

    spec =
      spec!(
        name: "timeout",
        argv: ["/bin/sh", script, marker],
        timeout_ms: 50
      )

    assert {:ok, result} = Runner.run(spec, File.cwd!())
    assert result["status"] == "timeout"
    Process.sleep(500)
    refute File.exists?(marker)
    File.rm_rf!(root)
  end

  test "cancellation is distinct from timeout" do
    spec =
      spec!(
        name: "cancel",
        argv: ["/bin/sleep", "5"],
        timeout_ms: 5_000
      )

    assert {:ok, result} =
             Runner.run(spec, File.cwd!(), cancelled?: fn -> true end)

    assert result["status"] == "cancellation"
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
end
