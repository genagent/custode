defmodule Custode.Uploads do
  @moduledoc """
  The `uploads/` directory of a routine's workspace, addressed safely.

  An image dropped on a prompt box (#180) is written into the routine's own
  workspace as `uploads/<content-hash>.<ext>`, and the prompt text keeps the
  absolute path so the agent can `Read` it. This module is the one place that
  turns an `{agent, filename}` pair back into a file on disk and into the URL
  the dashboard serves it at, so the web route and the thumbnail component
  cannot disagree about what is reachable.

  Nothing outside a routine's own `uploads/` is addressable: the agent must
  name a routine in the live roster, the filename is reduced to its basename
  (so an encoded `../` in the URL cannot climb out), the extension must be one
  the upload boxes accept, and the file must actually be a regular file.
  """

  @image_types ~w(.png .jpg .jpeg .gif .webp)

  @doc "The image extensions a dropped file may carry."
  def image_types, do: @image_types

  @doc """
  The on-disk path of one uploaded image, or `:error` when it is not
  reachable -- unknown routine, non-image name, or no such file.
  """
  def path(agent, file) when is_binary(agent) and is_binary(file) do
    name = Path.basename(file)

    with true <- Path.extname(String.downcase(name)) in @image_types,
         routine when not is_nil(routine) <- Custode.Routine.get(agent),
         resolved = Path.join([Path.expand(routine.workspace), "uploads", name]),
         true <- File.regular?(resolved) do
      {:ok, resolved}
    else
      _unreachable -> :error
    end
  end

  def path(_agent, _file), do: :error

  @doc """
  The dashboard URL for an uploaded image, or `nil` when the file is not
  there. The janitor ages `uploads/` out at `:uploads_days` while the feed
  entry that named the file lives longer, so a nil here is ordinary.
  """
  def url(agent, file) do
    case path(agent, file) do
      {:ok, _path} -> "/agents/#{encode(agent)}/uploads/#{encode(Path.basename(file))}"
      :error -> nil
    end
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
