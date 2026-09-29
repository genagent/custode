defmodule Custode.OperatorSkillTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.OperatorSkill

  setup do
    root = Path.join(System.tmp_dir!(), uid("operator-skill"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "installs the complete shared package in both host skill directories", %{root: root} do
    claude_home = Path.join(root, "claude")
    codex_home = Path.join(root, "codex")

    assert {:ok, [claude, codex]} =
             OperatorSkill.install(:all, claude_home: claude_home, codex_home: codex_home)

    assert claude.status == :installed
    assert claude.target == :claude
    assert claude.version == OperatorSkill.version()
    assert codex.status == :installed
    assert codex.target == :codex
    refute claude.digest == codex.digest

    claude_skill = File.read!(Path.join(claude.path, "SKILL.md"))
    assert frontmatter(claude_skill)["disable-model-invocation"] == "true"

    assert File.read!(Path.join(codex.path, "SKILL.md")) ==
             File.read!(OperatorSkill.source_path())

    for result <- [claude, codex] do
      assert File.exists?(Path.join(result.path, "references/lifecycle.md"))
      assert File.exists?(Path.join(result.path, "references/troubleshooting.md"))
      assert File.exists?(Path.join(result.path, "references/self-maintenance.md"))
      assert File.exists?(Path.join(result.path, "agents/openai.yaml"))

      manifest =
        result.path |> Path.join(".custode-package.json") |> File.read!() |> Jason.decode!()

      assert manifest["schema"] == 1
      assert manifest["name"] == OperatorSkill.name()
      assert manifest["version"] == OperatorSkill.version()
      assert manifest["digest"] == result.digest
      assert map_size(manifest["files"]) == 5
    end
  end

  test "the packaged artifact declares its contract and Codex invocation boundary" do
    source = File.read!(OperatorSkill.source_path())
    openai = File.read!(Path.join(OperatorSkill.source_dir(), "agents/openai.yaml"))

    assert source =~ "version: #{OperatorSkill.version()}"
    assert source =~ "Contract: `#{OperatorSkill.version()}`"
    refute source =~ "disable-model-invocation"

    assert openai == """
           interface:
             display_name: "Custode Operator"
             short_description: "Operate and maintain a local Custode fleet"
             default_prompt: "Use $custode-operator to operate this Custode installation."

           policy:
             allow_implicit_invocation: false
           """
  end

  test "an identical installation and digest are deterministic", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]

    assert {:ok, [%{status: :installed, digest: digest}]} =
             OperatorSkill.install(:codex, opts)

    assert {:ok, [%{status: :current, digest: ^digest}]} =
             OperatorSkill.install(:codex, opts)

    assert {:ok, %{state: :current, expected_digest: ^digest, installed_digest: ^digest}} =
             OperatorSkill.status(:codex, opts)
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

    assert {:ok, %{state: :current}} = OperatorSkill.status(:codex, opts)
  end

  test "a cross-process lock fails before writes and is released for retry", %{root: root} do
    opts = [
      codex_home: Path.join(root, "codex"),
      install_lock_root: Path.join(root, "locks")
    ]

    skill_dir = OperatorSkill.destination(:codex, opts)
    lock_paths = OperatorSkill.install_lock_paths(:codex, opts)
    held_lock = List.last(lock_paths)

    File.mkdir_p!(Path.dirname(held_lock))
    File.write!(held_lock, "other installer", [:exclusive])
    on_exit(fn -> File.rm(held_lock) end)

    assert {:error, {:install_busy, ^held_lock}} = OperatorSkill.install(:codex, opts)
    refute File.exists?(skill_dir)

    assert Enum.all?(lock_paths -- [held_lock], &(not File.exists?(&1)))

    File.rm!(held_lock)
    assert {:ok, [%{status: :installed}]} = OperatorSkill.install(:codex, opts)
    assert Enum.all?(lock_paths, &(not File.exists?(&1)))
  end

  test "refuses a symlinked install lock root without touching its target", %{root: root} do
    target = Path.join(root, "lock-target")
    lock_root = Path.join(root, "locks-link")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    File.ln_s!(target, lock_root)

    opts = [codex_home: Path.join(root, "codex"), install_lock_root: lock_root]
    mode_before = File.stat!(target).mode

    assert {:error, {:lock_failed, ^lock_root, {:unsafe_type, :symlink}}} =
             OperatorSkill.install(:codex, opts)

    assert File.stat!(target).mode == mode_before
    assert Path.wildcard(Path.join(target, "*.lock")) == []
    refute File.exists?(OperatorSkill.destination(:codex, opts))
  end

  test "lock paths do not depend on the process temporary directory", %{root: root} do
    previous = System.get_env("TMPDIR")

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    opts = [codex_home: Path.join(root, "codex")]
    System.put_env("TMPDIR", Path.join(root, "tmp-a"))
    first = OperatorSkill.install_lock_paths(:codex, opts)
    System.put_env("TMPDIR", Path.join(root, "tmp-b"))
    second = OperatorSkill.install_lock_paths(:codex, opts)

    assert first == second
  end

  test "reports missing and modified installations", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    skill_dir = OperatorSkill.destination(:codex, opts)

    assert {:ok, %{state: :missing}} = OperatorSkill.status(:codex, opts)
    assert {:ok, [_installed]} = OperatorSkill.install(:codex, opts)

    File.write!(Path.join(skill_dir, "references/lifecycle.md"), "local edit\n")

    assert {:ok, %{state: :modified}} = OperatorSkill.status(:codex, opts)
    assert {:error, {:conflict, ^skill_dir}} = OperatorSkill.install(:codex, opts)
  end

  test "recognizes an untouched legacy v1 install but protects an edited one", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    skill_dir = OperatorSkill.destination(:codex, opts)
    File.mkdir_p!(skill_dir)

    legacy = Path.expand("../fixtures/operator_skill_v1.md", __DIR__)
    File.cp!(legacy, Path.join(skill_dir, "SKILL.md"))

    assert {:ok, %{state: :stale, installed_version: "custode.operator-skill.v1"}} =
             OperatorSkill.status(:codex, opts)

    assert {:error, {:stale, ^skill_dir}} = OperatorSkill.install(:codex, opts)

    assert {:ok, [%{status: :updated}]} =
             OperatorSkill.install(:codex, Keyword.put(opts, :force, true))

    assert {:ok, %{state: :current}} = OperatorSkill.status(:codex, opts)

    File.rm_rf!(skill_dir)
    File.mkdir_p!(skill_dir)
    File.cp!(legacy, Path.join(skill_dir, "SKILL.md"))
    File.write!(Path.join(skill_dir, "SKILL.md"), File.read!(legacy) <> "\nlocal edit\n")
    assert {:ok, %{state: :modified}} = OperatorSkill.status(:codex, opts)
  end

  test "an incomplete package is modified and cannot overwrite residual edits", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    assert {:ok, [_installed]} = OperatorSkill.install(:codex, opts)

    skill_dir = OperatorSkill.destination(:codex, opts)
    reference = Path.join(skill_dir, "references/lifecycle.md")
    File.write!(reference, "local edit\n")
    File.rm!(Path.join(skill_dir, "SKILL.md"))

    assert {:ok, %{state: :modified}} = OperatorSkill.status(:codex, opts)
    assert {:error, {:conflict, ^skill_dir}} = OperatorSkill.install(:codex, opts)
    assert File.read!(reference) == "local edit\n"
  end

  test "a legacy upgrade protects files that collide with new package paths", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    skill_dir = OperatorSkill.destination(:codex, opts)
    reference = Path.join(skill_dir, "references/lifecycle.md")
    File.mkdir_p!(Path.dirname(reference))

    File.cp!(
      Path.expand("../fixtures/operator_skill_v1.md", __DIR__),
      Path.join(skill_dir, "SKILL.md")
    )

    File.write!(reference, "unrelated local reference\n")

    assert {:ok, %{state: :modified}} = OperatorSkill.status(:codex, opts)
    assert {:error, {:conflict, ^skill_dir}} = OperatorSkill.install(:codex, opts)
    assert File.read!(reference) == "unrelated local reference\n"
  end

  test "an unknown self-consistent manifest cannot claim a safe stale upgrade", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    assert {:ok, [_installed]} = OperatorSkill.install(:codex, opts)

    skill_dir = OperatorSkill.destination(:codex, opts)
    manifest_path = Path.join(skill_dir, ".custode-package.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    File.write!(manifest_path, Jason.encode!(%{manifest | "version" => "unpublished"}))

    assert {:ok, %{state: :modified, installed_version: "unpublished"}} =
             OperatorSkill.status(:codex, opts)

    assert {:error, {:conflict, ^skill_dir}} = OperatorSkill.install(:codex, opts)
  end

  test "protects local changes and preflights all targets before writing", %{root: root} do
    claude_home = Path.join(root, "claude")
    codex_home = Path.join(root, "codex")
    codex_skill_dir = OperatorSkill.destination(:codex, codex_home: codex_home)
    File.mkdir_p!(codex_skill_dir)
    File.write!(Path.join(codex_skill_dir, "SKILL.md"), "local instructions\n")

    assert {:error, {:conflict, ^codex_skill_dir}} =
             OperatorSkill.install(:all,
               claude_home: claude_home,
               codex_home: codex_home
             )

    refute File.exists?(
             Path.join(OperatorSkill.destination(:claude, claude_home: claude_home), "SKILL.md")
           )

    assert File.read!(Path.join(codex_skill_dir, "SKILL.md")) == "local instructions\n"
  end

  test "refuses two host packages that resolve to the same destination", %{root: root} do
    shared_home = Path.join(root, "shared")
    skill_dir = Path.join([shared_home, "skills", OperatorSkill.name()])

    assert {:error, {:duplicate_destination, ^skill_dir}} =
             OperatorSkill.install(:all,
               claude_home: shared_home,
               codex_home: shared_home
             )

    refute File.exists?(skill_dir)
  end

  test "detects duplicate host destinations through a parent symlink", %{root: root} do
    real_home = Path.join(root, "real")
    linked_home = Path.join(root, "linked")
    File.mkdir_p!(Path.join(real_home, "skills"))
    File.ln_s!(Path.basename(real_home), linked_home)
    skill_dir = Path.join([real_home, "skills", OperatorSkill.name()])

    assert {:error, {:duplicate_destination, duplicate}} =
             OperatorSkill.install(:all,
               claude_home: real_home,
               codex_home: linked_home
             )

    assert duplicate in [
             skill_dir,
             Path.join([linked_home, "skills", OperatorSkill.name()])
           ]

    refute File.exists?(skill_dir)
  end

  test "conservatively rejects case variants of a future destination", %{root: root} do
    upper_home = Path.join(root, "Shared")
    lower_home = Path.join(root, "shared")

    assert {:error, {:duplicate_destination, _path}} =
             OperatorSkill.install(:all,
               claude_home: upper_home,
               codex_home: lower_home
             )

    refute File.exists?(upper_home)
    refute File.exists?(lower_home)
  end

  test "rejects canonically equivalent Unicode variants of a future destination", %{root: root} do
    composed_home = Path.join(root, "Café")
    decomposed_home = Path.join(root, "Cafe\u0301")

    assert {:error, {:duplicate_destination, _path}} =
             OperatorSkill.install(:all,
               claude_home: composed_home,
               codex_home: decomposed_home
             )

    refute File.exists?(composed_home)
    refute File.exists?(decomposed_home)
  end

  test "rejects Unicode case-fold equivalents of a future destination", %{root: root} do
    mixed_home = Path.join(root, "Straße")
    folded_home = Path.join(root, "STRASSE")

    assert {:error, {:duplicate_destination, _path}} =
             OperatorSkill.install(:all,
               claude_home: mixed_home,
               codex_home: folded_home
             )

    refute File.exists?(mixed_home)
    refute File.exists?(folded_home)
  end

  test "force restores managed files and preserves unrelated local files", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    assert {:ok, [_installed]} = OperatorSkill.install(:codex, opts)

    skill_dir = OperatorSkill.destination(:codex, opts)
    File.write!(Path.join(skill_dir, "SKILL.md"), "local instructions\n")
    File.write!(Path.join(skill_dir, "local-note.md"), "keep me\n")

    assert {:ok, [%{status: :updated}]} =
             OperatorSkill.install(:codex, Keyword.put(opts, :force, true))

    assert File.read!(Path.join(skill_dir, "SKILL.md")) == File.read!(OperatorSkill.source_path())
    assert File.read!(Path.join(skill_dir, "local-note.md")) == "keep me\n"
    assert {:ok, %{state: :current}} = OperatorSkill.status(:codex, opts)
  end

  test "refuses symlinks at the skill root or inside the managed tree", %{root: root} do
    codex_home = Path.join(root, "codex")
    outside = Path.join(root, "outside")
    skill_dir = OperatorSkill.destination(:codex, codex_home: codex_home)
    File.mkdir_p!(Path.dirname(skill_dir))
    File.mkdir_p!(outside)
    File.ln_s!(outside, skill_dir)

    assert {:error, {:symlink, ^skill_dir}} =
             OperatorSkill.install(:codex, codex_home: codex_home, force: true)

    File.rm!(skill_dir)
    File.mkdir_p!(skill_dir)

    File.cp!(
      Path.expand("../fixtures/operator_skill_v1.md", __DIR__),
      Path.join(skill_dir, "SKILL.md")
    )

    references = Path.join(skill_dir, "references")
    File.ln_s!(outside, references)

    assert {:error, {:symlink, ^references}} =
             OperatorSkill.install(:codex, codex_home: codex_home, force: true)
  end

  test "preflights non-directory path prefixes before writing any package file", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    skill_dir = OperatorSkill.destination(:codex, opts)
    references = Path.join(skill_dir, "references")
    File.mkdir_p!(skill_dir)
    File.write!(references, "local file\n")

    assert {:error, {:unexpected_file_type, ^references, :regular}} =
             OperatorSkill.install(:codex, opts)

    refute File.exists?(Path.join(skill_dir, "SKILL.md"))
    assert File.read!(references) == "local file\n"
  end

  test "a malformed or path-traversing manifest is modified, never followed", %{root: root} do
    opts = [codex_home: Path.join(root, "codex")]
    assert {:ok, [_installed]} = OperatorSkill.install(:codex, opts)
    skill_dir = OperatorSkill.destination(:codex, opts)

    malicious = %{
      "schema" => 1,
      "name" => OperatorSkill.name(),
      "version" => OperatorSkill.version(),
      "digest" => "not-real",
      "files" => %{"../outside" => "not-real"}
    }

    File.write!(Path.join(skill_dir, ".custode-package.json"), Jason.encode!(malicious))
    assert {:ok, %{state: :modified}} = OperatorSkill.status(:codex, opts)
    refute File.exists?(Path.join(root, "outside"))
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

  defp frontmatter(content) do
    ["", yaml, _body] = String.split(content, "---", parts: 3)

    yaml
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> String.split(line, ":", parts: 2) end)
    |> Map.new(fn [key, value] -> {String.trim(key), String.trim(value)} end)
  end
end
