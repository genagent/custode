defmodule Custode.AssuranceNativeProofTaskTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Custode.Assurance.Proof

  setup do
    tmpdir = Path.join(System.tmp_dir!(), "proof-guard-#{Ecto.UUID.generate()}")
    File.mkdir!(tmpdir)
    File.chmod!(tmpdir, 0o700)
    on_exit(fn -> File.rm_rf!(tmpdir) end)
    %{tmpdir: tmpdir, root: Path.join(tmpdir, "fresh")}
  end

  test "paid task refuses wrong environment, missing opt-in and existing application before boot",
       ctx do
    context = context(ctx)
    args = ["--root", ctx.root]
    assert {:error, "MIX_ENV=test required"} = Proof.prepare(args, %{context | env: :dev})

    assert {:error, "explicit paid opt-in required"} =
             Proof.prepare(args, %{context | opt_in: nil})

    assert {:error, "application already running"} =
             Proof.prepare(args, %{context | app_running: true})

    refute File.exists?(ctx.root)
  end

  test "task requires private existing TMPDIR and a fresh direct child, with strict arguments",
       ctx do
    context = context(ctx)
    assert {:ok, %{root: root}} = Proof.prepare(["--root", ctx.root], context)
    assert root == ctx.root
    assert {:error, _} = Proof.prepare(["--root", ctx.root, "--yolo"], context)
    assert {:error, _} = Proof.prepare(["--root", Path.join(ctx.root, "nested")], context)
    assert {:error, _} = Proof.prepare(["--root", ctx.root], %{context | tmpdir: nil})
    File.mkdir!(ctx.root)
    assert {:error, _} = Proof.prepare(["--root", ctx.root], context)
    File.chmod!(ctx.tmpdir, 0o755)
    assert {:error, _} = Proof.prepare(["--root", ctx.root], context)
  end

  test "symlink destinations are refused without touching the target", ctx do
    target = Path.join(ctx.tmpdir, "target")
    File.mkdir!(target)
    File.ln_s!(target, ctx.root)
    assert {:error, _} = Proof.prepare(["--root", ctx.root], context(ctx))
    assert File.ls!(target) == []
  end

  test "reassessment accepts only private completed proof records and never a symlink", ctx do
    File.mkdir!(ctx.root)
    File.chmod!(ctx.root, 0o700)
    database = Path.join(ctx.root, "operations.db")
    report_path = Path.join(ctx.root, "result.json")
    File.write!(database, "guard fixture only")
    File.chmod!(database, 0o600)

    report = %{
      "schema" => "custode.native-assurance-proof.v1",
      "private_store" => database,
      "cases" => [%{}, %{}],
      "native_calls" => List.duplicate(%{"status" => "completed"}, 4)
    }

    File.write!(report_path, Jason.encode!(report))
    File.chmod!(report_path, 0o600)
    args = ["--root", ctx.root, "--reassess"]
    assert {:ok, %{reassess: true}} = Proof.prepare(args, context(ctx))
    assert {:error, _} = Proof.prepare(["--root", ctx.root], context(ctx))
    File.write!(report_path, Jason.encode!(%{report | "native_calls" => []}))
    assert {:error, _} = Proof.prepare(args, context(ctx))
    File.write!(report_path, Jason.encode!(report))
    File.chmod!(report_path, 0o644)
    assert {:error, _} = Proof.prepare(args, context(ctx))
    File.chmod!(report_path, 0o600)
    File.rm!(database)
    File.ln_s!(report_path, database)
    assert {:error, _} = Proof.prepare(args, context(ctx))
  end

  defp context(ctx),
    do: %{env: :test, opt_in: "1", tmpdir: ctx.tmpdir, app_running: false}
end
