defmodule Mix.Tasks.Custode.Mcp.Docs do
  @shortdoc "Generate or check the language-neutral MCP reference without starting Custode"
  @moduledoc """
  Run `mix custode.mcp.docs` to regenerate the Markdown and JSON reference.
  Run `mix custode.mcp.docs --check` to fail on missing/stale behavior notes or
  generated documents. Compiles definitions but never starts the application.
  """
  use Mix.Task

  alias Custode.MCP.Reference

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [check: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix custode.mcp.docs [--check]")
    end

    Mix.Task.run("compile")
    documents = Reference.documents()

    if opts[:check] do
      stale = for {path, expected} <- documents, File.read(path) != {:ok, expected}, do: path

      if stale != [] do
        Mix.raise(
          "MCP reference is stale: #{Enum.join(Enum.sort(stale), ", ")}. Run mix custode.mcp.docs"
        )
      end

      Mix.shell().info("MCP reference is current")
    else
      for {path, content} <- documents do
        File.write!(path, content)
        Mix.shell().info("Wrote #{path}")
      end
    end
  end
end
