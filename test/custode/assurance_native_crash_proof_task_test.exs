defmodule Custode.AssuranceNativeCrashProofTaskTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Custode.Assurance.CrashProof

  setup do
    tmpdir = Path.join(System.tmp_dir!(), "crash-guard-#{Ecto.UUID.generate()}")
    File.mkdir!(tmpdir)
    File.chmod!(tmpdir, 0o700)
    on_exit(fn -> File.rm_rf!(tmpdir) end)
    %{tmpdir: tmpdir, root: Path.join(tmpdir, "fresh")}
  end

  test "default-off phase refuses production, existing application and missing opt-in", ctx do
    for context <- [
          Map.put(context(ctx), :env, :dev),
          Map.put(context(ctx), :opt_in, nil),
          Map.put(context(ctx), :app_running, true)
        ] do
      assert {:error, _} = CrashProof.prepare(args(ctx), context)
      refute File.exists?(ctx.root)
    end
  end

  test "strict phase and isolated private root are required before boot", ctx do
    assert {:ok, %{synthetic: false}} = CrashProof.prepare(args(ctx), context(ctx))

    for bad <- [
          args(ctx) ++ ["--yolo"],
          args(ctx) ++ ["--provider", "claude"],
          ["--root", ctx.root, "--provider", "unknown", "--phase", "worker"],
          ["--root", Path.join(ctx.root, "nested"), "--provider", "codex", "--phase", "worker"]
        ] do
      assert {:error, _} = CrashProof.prepare(bad, context(ctx))
    end

    File.mkdir!(ctx.root)
    assert {:error, _} = CrashProof.prepare(args(ctx), context(ctx))
    File.rmdir!(ctx.root)
    File.ln_s!(ctx.tmpdir, ctx.root)
    assert {:error, _} = CrashProof.prepare(args(ctx), context(ctx))
    File.rm!(ctx.root)
    File.chmod!(ctx.tmpdir, 0o755)
    assert {:error, _} = CrashProof.prepare(args(ctx), context(ctx))
  end

  test "recovery requires private regular store and original context", ctx do
    File.mkdir!(ctx.root)
    File.chmod!(ctx.root, 0o700)
    recover = ["--root", ctx.root, "--provider", "codex", "--phase", "recover"]
    assert {:error, _} = CrashProof.prepare(recover, context(ctx))

    for name <- ~w(operations.db case-state.json) do
      path = Path.join(ctx.root, name)
      File.write!(path, "guard fixture")
      File.chmod!(path, 0o600)
    end

    assert {:ok, _} = CrashProof.prepare(recover, context(ctx))
    File.chmod!(Path.join(ctx.root, "operations.db"), 0o644)
    assert {:error, _} = CrashProof.prepare(recover, context(ctx))
    File.rm!(Path.join(ctx.root, "operations.db"))
    File.ln_s!(Path.join(ctx.root, "case-state.json"), Path.join(ctx.root, "operations.db"))
    assert {:error, _} = CrashProof.prepare(recover, context(ctx))
  end

  test "external controller adversarial tests make no model calls" do
    {output, status} =
      System.cmd(
        "python3",
        [
          "-B",
          "-m",
          "unittest",
          "discover",
          "-s",
          "spikes/assurance",
          "-p",
          "test_native_crash.py"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "OK"
  end

  defp args(ctx), do: ["--root", ctx.root, "--provider", "codex", "--phase", "worker"]
  defp context(ctx), do: %{env: :test, opt_in: "1", tmpdir: ctx.tmpdir, app_running: false}
end
