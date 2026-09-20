defmodule Custode.Operator.Attachments do
  @moduledoc """
  An image attached to a message: where it is stored and how it reaches the
  agent (#180), in one place (#450).

  A dropped image reaches the agent as a PATH, not as an attachment. claude
  reads images natively through Read, and a file in the routine's own
  workspace is already inside its readable world, so this needs no wrapper and
  no protocol change. The path is absolute because a routine's working
  directory is not always its workspace: a repo-tied routine runs in the
  checkout, and a relative `uploads/` would not resolve from there.

  This is the code that writes an operator-supplied file to disk, which is why
  there is one copy of it. Two rules keep that write boring:

    * the stored name is a hash of the CONTENT. The same screenshot dropped
      twice is one file, and a client filename never steers the write.
    * the extension comes from an allowlist. Anything else is stored as `.png`.
  """

  @image_types ~w(.png .jpg .jpeg .gif .webp)
  @max_bytes 10_000_000

  @doc "The extensions an upload may carry. Also the `accept:` list for the form."
  @spec image_types() :: [String.t()]
  def image_types, do: @image_types

  @doc "The largest image accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Copy an uploaded temp file into `routine`'s `workspace/uploads/` and return
  the absolute path it now lives at.
  """
  @spec store!(map(), Path.t(), String.t()) :: Path.t()
  def store!(%{workspace: workspace}, tmp_path, client_name) do
    dir = Path.join(Path.expand(workspace), "uploads")
    File.mkdir_p!(dir)

    dest = Path.join(dir, name(tmp_path, client_name))
    File.cp!(tmp_path, dest)
    dest
  end

  @doc """
  The message as the agent receives it: the operator's text, then one line per
  image telling the agent where it is and to read it first.
  """
  @spec compose(String.t(), [Path.t()]) :: String.t()
  def compose(text, []), do: text

  def compose(text, paths) do
    [String.trim(text) | Enum.map(paths, &"attached image: #{&1} -- Read it before answering")]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp name(tmp_path, client_name) do
    hash =
      :sha256
      |> :crypto.hash(File.read!(tmp_path))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    hash <> extension(client_name)
  end

  defp extension(client_name) do
    extension = client_name |> Path.extname() |> String.downcase()
    if extension in @image_types, do: extension, else: ".png"
  end
end
