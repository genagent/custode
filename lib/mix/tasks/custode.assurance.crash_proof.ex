defmodule Mix.Tasks.Custode.Assurance.CrashProof do
  @moduledoc "Default-off isolated phases, guarded before application boot."
  @shortdoc "Explicit isolated worker/recovery phases for the native crash proof"
  use Mix.Task
  alias Custode.Assurance.Native.CrashProof

  def run(args) do
    context = %{
      env: Mix.env(),
      opt_in: System.get_env("CUSTODE_NATIVE_CRASH_PROOF"),
      tmpdir: System.get_env("TMPDIR"),
      app_running: not is_nil(Process.whereis(Custode.Repo))
    }

    case prepare(args, context) do
      {:ok, options} -> boot(options)
      {:error, reason} -> Mix.raise("native crash proof refused: #{reason}")
    end
  end

  def prepare(args, context) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          root: [:string, :keep],
          provider: [:string, :keep],
          phase: [:string, :keep],
          synthetic: [:boolean, :keep],
          claude_model: [:string, :keep],
          codex_model: [:string, :keep]
        ]
      )

    root = opts[:root]
    phase = opts[:phase]

    valid =
      allowed_context?(context) and valid_args?(opts, rest, invalid) and
        valid_root?(root, phase, context.tmpdir)

    if valid,
      do:
        {:ok,
         %{
           root: Path.expand(root),
           provider: opts[:provider],
           phase: phase,
           synthetic: opts[:synthetic] || false,
           claude_model: opts[:claude_model] || "sonnet",
           codex_model: opts[:codex_model] || "gpt-5.5"
         }},
      else:
        {:error,
         "test environment, explicit opt-in, isolated private root and exact phase/provider required"}
  end

  defp allowed_context?(context),
    do: context.env == :test and context.opt_in == "1" and not context.app_running

  defp valid_args?(opts, rest, invalid),
    do:
      rest == [] and invalid == [] and opts[:provider] in ~w(claude codex) and
        opts[:phase] in ~w(worker recover) and
        length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0)))

  defp valid_root?(root, phase, tmpdir) when is_binary(root) and is_binary(tmpdir) do
    private_dir?(tmpdir) and Path.type(root) == :absolute and
      Path.dirname(Path.expand(root)) == Path.expand(tmpdir) and phase_root?(phase, root)
  end

  defp valid_root?(_root, _phase, _tmpdir), do: false
  defp phase_root?("worker", root), do: match?({:error, :enoent}, File.lstat(root))

  defp phase_root?("recover", root),
    do:
      private_dir?(root) and
        private_file?(Path.join(root, "operations.db")) and
        private_file?(Path.join(root, "case-state.json"))

  defp phase_root?(_phase, _root), do: false

  defp private_dir?(path), do: private?(path, :directory)
  defp private_file?(path), do: private?(path, :regular)

  defp private?(path, type) do
    case File.lstat(path) do
      {:ok, %{type: ^type, mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      _other -> false
    end
  end

  defp boot(options) do
    root = options.root

    if options.phase == "worker" do
      File.mkdir!(root)
      File.chmod!(root, 0o700)
    end

    Mix.Task.run("app.config")
    System.put_env("CUSTODE_HOME", root)
    config = Application.fetch_env!(:custode, Custode.Repo)

    Application.put_env(
      :custode,
      Custode.Repo,
      Keyword.put(config, :database, Path.join(root, "operations.db"))
    )

    Application.put_env(:custode, :routines, [])
    Application.put_env(:custode, :mcp_config_dir, Path.join(root, "mcp"))
    Application.put_env(:custode, :feed_path, Path.join(root, "feed.jsonl"))
    Application.put_env(:custode, :assurance_crash_proof_root, root)
    Mix.Task.run("app.start")
    File.chmod!(Path.join(root, "operations.db"), 0o600)

    result =
      if options.phase == "worker",
        do: CrashProof.worker(options),
        else: CrashProof.recover(options)

    if options.phase == "recover" and not result["passed"],
      do: Mix.raise("recovery controls incomplete; inspect private report")

    Mix.shell().info("Crash proof phase retained privately.")
  end
end
