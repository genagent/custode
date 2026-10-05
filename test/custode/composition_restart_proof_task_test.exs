defmodule Custode.CompositionRestartProofTaskTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Custode.Composition.Proof

  setup do
    tmp = Path.join(System.tmp_dir!(), "composition-guard-#{Ecto.UUID.generate()}")
    File.mkdir!(tmp)
    File.chmod!(tmp, 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, root: Path.join(tmp, "proof")}
  end

  test "explicit nonpaid task refuses normal environments and an already running application",
       ctx do
    args = ["--root", ctx.root, "--phase", "init"]
    base = context(ctx)
    assert {:ok, _} = Proof.prepare(args, base)

    for invalid <- [%{base | env: :dev}, %{base | opt_in: nil}, %{base | app_running: true}] do
      assert {:error, _} = Proof.prepare(args, invalid)
    end

    refute File.exists?(ctx.root)
  end

  test "fresh and reopened phases require exact arguments and private regular records", ctx do
    base = context(ctx)
    args = ["--root", ctx.root, "--phase", "init"]
    assert {:error, _} = Proof.prepare(args ++ ["--phase", "final"], base)
    assert {:error, _} = Proof.prepare(args ++ ["--extra"], base)
    assert {:error, _} = Proof.prepare(["--root", ctx.root, "--phase", "final"], base)
    File.mkdir!(ctx.root)
    File.chmod!(ctx.root, 0o700)
    assert {:error, _} = Proof.prepare(args, base)

    for name <- ~w(operations.db manifest.json) do
      path = Path.join(ctx.root, name)
      File.write!(path, "guard fixture only")
      File.chmod!(path, 0o600)
    end

    assert {:ok, _} = Proof.prepare(["--root", ctx.root, "--phase", "reopen"], base)
    File.chmod!(Path.join(ctx.root, "manifest.json"), 0o644)
    assert {:error, _} = Proof.prepare(["--root", ctx.root, "--phase", "reopen"], base)
  end

  test "symlink roots and recorded stores are refused without following them", ctx do
    target = Path.join(ctx.tmp, "target")
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, ctx.root)
    assert {:error, _} = Proof.prepare(["--root", ctx.root, "--phase", "init"], context(ctx))
    assert File.ls!(target) == []
    File.rm!(ctx.root)
    File.mkdir!(ctx.root)
    File.chmod!(ctx.root, 0o700)
    File.ln_s!(target, Path.join(ctx.root, "operations.db"))
    File.write!(Path.join(ctx.root, "manifest.json"), "fixture")
    File.chmod!(Path.join(ctx.root, "manifest.json"), 0o600)
    assert {:error, _} = Proof.prepare(["--root", ctx.root, "--phase", "final"], context(ctx))
  end

  defp context(ctx), do: %{env: :test, opt_in: "1", tmpdir: ctx.tmp, app_running: false}
end
