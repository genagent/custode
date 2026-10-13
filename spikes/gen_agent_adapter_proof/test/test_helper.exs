ExUnit.start(assert_receive_timeout: 5_000)

:ets.new(AdapterProof.Runtime, [:named_table, :public])
Code.require_file("priv/repo/migrations/20261013223913_create_proof_journal.exs")

sha256 = fn path -> :crypto.hash(:sha256, File.read!(path)) |> Base.encode16() end
{:ok, shim} = Forcola.Shim.path()
python = System.find_executable("python3")
{python_version, 0} = System.cmd(python, ["--version"])
{source_base, 0} = System.cmd("git", ["rev-parse", "HEAD"])
{dirty, 0} = System.cmd("git", ["status", "--porcelain"])

packages =
  for app <- [:gen_agent, :gen_agent_claude, :claude_wrapper, :forcola, :oban, :ecto_sqlite3],
      into: %{} do
    {app, Application.spec(app, :vsn) |> to_string()}
  end

source_files = ["mix.exs", "mix.lock"] ++ Path.wildcard("{config,lib,test,priv}/**/*.{ex,exs,py}")

manifest = %{
  packages: packages,
  elixir: System.version(),
  otp: System.otp_release(),
  architecture: to_string(:erlang.system_info(:system_architecture)),
  source_base: String.trim(source_base),
  dirty: dirty != "",
  python: python,
  python_version: String.trim(python_version),
  shim_sha256: sha256.(shim),
  files_sha256: Map.new(source_files, &{&1, sha256.(&1)}),
  provider: "synthetic only",
  seed: ExUnit.configuration()[:seed]
}

File.mkdir_p!("tmp/evidence")

File.write!(
  "tmp/evidence/manifest-#{ExUnit.configuration()[:seed]}.json",
  Jason.encode!(manifest, pretty: true)
)
