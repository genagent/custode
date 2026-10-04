defmodule Mix.Tasks.Custode.Assurance.Proof do
  @shortdoc "Run four explicitly opted-in native assurance calls in a fresh test-only store"
  @moduledoc """
  This task refuses development/production environments and existing stores.
  It requires CUSTODE_NATIVE_ASSURANCE_PROOF=1 and an existing private TMPDIR.
  The --root destination must not exist. With --reassess, only a private
  recorded proof is accepted; it appends observations without launching a model.
  No provider runs in ordinary CI.

      MIX_ENV=test CUSTODE_NATIVE_ASSURANCE_PROOF=1 mix custode.assurance.proof --root /private/tmp/proof-795
  """
  use Mix.Task
  alias Custode.Assurance.Native.Proof

  @impl true
  def run(args) do
    context = %{
      env: Mix.env(),
      opt_in: System.get_env("CUSTODE_NATIVE_ASSURANCE_PROOF"),
      tmpdir: System.get_env("TMPDIR"),
      app_running: not is_nil(Process.whereis(Custode.Repo))
    }

    case prepare(args, context) do
      {:ok, options} -> boot_and_run(options)
      {:error, reason} -> Mix.raise("native assurance proof refused: #{reason}")
    end
  end

  @doc false
  def prepare(args, context) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [root: :string, claude_model: :string, codex_model: :string, reassess: :boolean]
      )

    cond do
      context.env != :test ->
        {:error, "MIX_ENV=test required"}

      context.opt_in != "1" ->
        {:error, "explicit paid opt-in required"}

      context.app_running ->
        {:error, "application already running"}

      rest != [] or invalid != [] ->
        {:error, "unknown arguments"}

      not private_directory?(context.tmpdir) ->
        {:error, "private existing TMPDIR required"}

      not valid_root?(opts, context.tmpdir) ->
        {:error, "fresh root or private recorded proof inside TMPDIR required"}

      true ->
        {:ok, Map.new(opts)}
    end
  end

  defp private_directory?(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      _other -> false
    end
  end

  defp private_directory?(_path), do: false

  defp valid_root?(opts, tmpdir) do
    if opts[:reassess],
      do: recorded_root?(opts[:root], tmpdir),
      else: fresh_root?(opts[:root], tmpdir)
  end

  defp recorded_root?(root, tmpdir) when is_binary(root) do
    report_path = Path.join(root, "result.json")
    database = Path.join(root, "operations.db")

    with true <- Path.type(root) == :absolute,
         true <- Path.dirname(Path.expand(root)) == Path.expand(tmpdir),
         true <- private_directory?(root),
         true <- private_file?(report_path),
         true <- private_file?(database),
         {:ok, bytes} <- File.read(report_path),
         {:ok, report} <- Jason.decode(bytes) do
      match?(%{"schema" => "custode.native-assurance-proof.v1"}, report) and
        report["private_store"] == database and
        is_list(report["cases"]) and length(report["cases"]) == 2 and
        is_list(report["native_calls"]) and length(report["native_calls"]) == 4 and
        Enum.all?(report["native_calls"], &match?(%{"status" => "completed"}, &1))
    else
      _other -> false
    end
  end

  defp recorded_root?(_root, _tmpdir), do: false

  defp private_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      _other -> false
    end
  end

  defp fresh_root?(root, tmpdir) when is_binary(root) do
    relative = Path.relative_to(Path.expand(root), Path.expand(tmpdir))

    Path.type(root) == :absolute and Path.dirname(Path.expand(root)) == Path.expand(tmpdir) and
      relative not in [".", ".."] and not File.exists?(root) and
      match?({:error, :enoent}, File.lstat(root))
  end

  defp fresh_root?(_root, _tmpdir), do: false

  defp boot_and_run(options) do
    root = Path.expand(options.root)

    unless options[:reassess] do
      File.mkdir!(root)
      File.chmod!(root, 0o700)
    end

    Mix.Task.run("app.config")
    System.put_env("CUSTODE_HOME", root)
    database = Path.join(root, "operations.db")
    repo = Application.fetch_env!(:custode, Custode.Repo)
    Application.put_env(:custode, Custode.Repo, Keyword.put(repo, :database, database))
    Application.put_env(:custode, :routines, [])
    Application.put_env(:custode, :mcp_config_dir, Path.join(root, "mcp"))
    Application.put_env(:custode, :feed_path, Path.join(root, "feed.jsonl"))
    Application.put_env(:custode, :assurance_native_proof_root, root)
    Mix.Task.run("app.start")
    File.chmod!(database, 0o600)

    {report, filename} =
      if options[:reassess],
        do: {Proof.reassess(options), "result-reassessed.json"},
        else: {Proof.run(options), "result.json"}

    Mix.shell().info("Native proof retained at #{Path.join(root, filename)}")

    if report["status"] != "passed",
      do: Mix.raise("native proof incomplete; inspect private report")
  end
end
