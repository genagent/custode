defmodule Mix.Tasks.Custode.Composition.Proof do
  @shortdoc "Explicit nonpaid composition persistence proof in an isolated test store"
  @moduledoc "No provider execution. Run init, reopen and final in separate OS processes."
  use Mix.Task
  alias Custode.ReadCompositions.RestartProof

  def run(args) do
    context = %{
      env: Mix.env(),
      opt_in: System.get_env("CUSTODE_COMPOSITION_RESTART_PROOF"),
      tmpdir: System.get_env("TMPDIR"),
      app_running: not is_nil(Process.whereis(Custode.Repo))
    }

    case prepare(args, context) do
      {:ok, options} -> boot(options)
      {:error, reason} -> Mix.raise("composition proof refused: #{reason}")
    end
  end

  def prepare(args, context) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [root: [:string, :keep], phase: [:string, :keep]])

    root = opts[:root]
    phase = opts[:phase]

    if valid_context?(context) and valid_args?(opts, rest, invalid) and
         valid_root?(root, phase, context.tmpdir) do
      {:ok, %{root: Path.expand(root), phase: phase}}
    else
      {:error, "test environment, opt-in, private fresh/recorded root and exact phase required"}
    end
  end

  defp valid_context?(context),
    do: context.env == :test and context.opt_in == "1" and not context.app_running

  defp valid_args?(opts, rest, invalid),
    do:
      rest == [] and invalid == [] and length(opts) == 2 and opts[:phase] in ~w(init reopen final)

  defp valid_root?(root, phase, tmpdir) when is_binary(root) and is_binary(tmpdir),
    do:
      private?(tmpdir, :directory) and Path.type(root) == :absolute and
        Path.dirname(Path.expand(root)) == Path.expand(tmpdir) and phase_root?(phase, root)

  defp valid_root?(_root, _phase, _tmpdir), do: false

  defp phase_root?("init", root), do: match?({:error, :enoent}, File.lstat(root))

  defp phase_root?(_phase, root),
    do:
      private?(root, :directory) and private?(Path.join(root, "operations.db"), :regular) and
        private?(Path.join(root, "manifest.json"), :regular)

  defp private?(path, type) do
    case File.lstat(path) do
      {:ok, %{type: ^type, mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      _other -> false
    end
  end

  defp boot(options) do
    if options.phase == "init" do
      File.mkdir!(options.root)
      File.chmod!(options.root, 0o700)
    end

    Mix.Task.run("app.config")
    System.put_env("CUSTODE_HOME", options.root)
    config = Application.fetch_env!(:custode, Custode.Repo)

    Application.put_env(
      :custode,
      Custode.Repo,
      Keyword.put(config, :database, Path.join(options.root, "operations.db"))
    )

    Application.put_env(:custode, :routines, [])
    Application.put_env(:custode, :mcp_config_dir, Path.join(options.root, "mcp"))
    Application.put_env(:custode, :feed_path, Path.join(options.root, "feed.jsonl"))
    Application.put_env(:custode, :composition_restart_proof_root, options.root)
    Mix.Task.run("app.start")
    File.chmod!(Path.join(options.root, "operations.db"), 0o600)
    RestartProof.run(options)
    Mix.shell().info("Nonpaid composition phase retained privately.")
  end
end
