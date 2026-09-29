defmodule Custode.OperatorSkillTest do
  use ExUnit.Case, async: true

  import Custode.TestHelpers

  alias Custode.OperatorSkill

  setup do
    root = Path.join(System.tmp_dir!(), uid("operator-skill"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "installs one shared artifact in both host skill directories", %{root: root} do
    claude_home = Path.join(root, "claude")
    codex_home = Path.join(root, "codex")

    assert {:ok, [claude, codex]} =
             OperatorSkill.install(:all, claude_home: claude_home, codex_home: codex_home)

    assert claude.status == :installed
    assert claude.target == :claude
    assert claude.version == OperatorSkill.version()
    assert codex.status == :installed
    assert codex.target == :codex

    source = File.read!(OperatorSkill.source_path())
    assert File.read!(Path.join(claude.path, "SKILL.md")) == source
    assert File.read!(Path.join(codex.path, "SKILL.md")) == source
  end

  test "the packaged artifact declares the installer's contract version" do
    source = File.read!(OperatorSkill.source_path())

    assert source =~ "version: #{OperatorSkill.version()}"
    assert source =~ "Contract: `#{OperatorSkill.version()}`"
  end

  test "an identical installation is idempotent", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]

    assert {:ok, [%{status: :installed}]} = OperatorSkill.install(:codex, opts)
    assert {:ok, [%{status: :current}]} = OperatorSkill.install(:codex, opts)
  end

  test "concurrent identical installs publish once without overwriting", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]

    results =
      1..32
      |> Task.async_stream(fn _caller -> OperatorSkill.install(:codex, opts) end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, [result]}} -> result end)

    assert Enum.count(results, &(&1.status == :installed)) == 1
    assert Enum.all?(results, &(&1.status in [:installed, :current]))

    destination = Path.join([opts[:codex_home], "skills", OperatorSkill.name(), "SKILL.md"])
    assert File.read!(destination) == File.read!(OperatorSkill.source_path())
  end

  test "protects local changes and preflights all targets before writing", %{root: root} do
    claude_home = Path.join(root, "claude")
    codex_home = Path.join(root, "codex")
    codex_skill = Path.join([codex_home, "skills", OperatorSkill.name(), "SKILL.md"])
    File.mkdir_p!(Path.dirname(codex_skill))
    File.write!(codex_skill, "local instructions\n")

    assert {:error, {:conflict, ^codex_skill}} =
             OperatorSkill.install(:all, claude_home: claude_home, codex_home: codex_home)

    refute File.exists?(Path.join([claude_home, "skills", OperatorSkill.name(), "SKILL.md"]))
    assert File.read!(codex_skill) == "local instructions\n"
  end

  test "force replaces only the packaged skill file", %{root: root} do
    codex_home = Path.join(root, "codex")
    skill_dir = Path.join([codex_home, "skills", OperatorSkill.name()])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "local instructions\n")
    File.write!(Path.join(skill_dir, "local-note.md"), "keep me\n")

    assert {:ok, [%{status: :updated}]} =
             OperatorSkill.install(:codex, codex_home: codex_home, force: true)

    assert File.read!(Path.join(skill_dir, "SKILL.md")) == File.read!(OperatorSkill.source_path())
    assert File.read!(Path.join(skill_dir, "local-note.md")) == "keep me\n"
  end

  test "refuses a symlinked skill destination", %{root: root} do
    codex_home = Path.join(root, "codex")
    outside = Path.join(root, "outside")
    skill_dir = Path.join([codex_home, "skills", OperatorSkill.name()])
    File.mkdir_p!(Path.dirname(skill_dir))
    File.mkdir_p!(outside)
    File.ln_s!(outside, skill_dir)

    assert {:error, {:symlink, ^skill_dir}} =
             OperatorSkill.install(:codex, codex_home: codex_home, force: true)

    refute File.exists?(Path.join(outside, "SKILL.md"))
  end

  test "uses each host's configured home without reading a secret", %{root: root} do
    env = fn
      "CLAUDE_CONFIG_DIR" -> Path.join(root, "claude-env")
      "CODEX_HOME" -> Path.join(root, "codex-env")
    end

    assert OperatorSkill.destination(:claude, env: env, user_home: root) ==
             Path.join([root, "claude-env", "skills", OperatorSkill.name()])

    assert OperatorSkill.destination(:codex, env: env, user_home: root) ==
             Path.join([root, "codex-env", "skills", OperatorSkill.name()])
  end

  test "falls back to conventional personal skill directories", %{root: root} do
    env = fn _variable -> nil end

    assert OperatorSkill.destination(:claude, env: env, user_home: root) ==
             Path.join([root, ".claude", "skills", OperatorSkill.name()])

    assert OperatorSkill.destination(:codex, env: env, user_home: root) ==
             Path.join([root, ".codex", "skills", OperatorSkill.name()])
  end
end
