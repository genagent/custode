defmodule Custode.Operator.AttachmentsTest do
  use ExUnit.Case, async: true

  import Custode.TestHelpers

  alias Custode.Operator.Attachments

  setup do
    workspace = tmp_workspace!()
    tmp = Path.join(System.tmp_dir!(), uid("upload"))
    File.write!(tmp, "not really a png")
    on_exit(fn -> File.rm(tmp) end)
    %{routine: %{workspace: workspace}, tmp: tmp, workspace: workspace}
  end

  test "an image is stored in the routine's own uploads dir, under an absolute path",
       %{routine: routine, tmp: tmp, workspace: workspace} do
    path = Attachments.store!(routine, tmp, "screenshot.png")

    assert Path.type(path) == :absolute
    assert Path.dirname(path) == Path.join(Path.expand(workspace), "uploads")
    assert File.read!(path) == "not really a png"
  end

  # this is the code that writes an operator-supplied file to disk
  test "the client's filename never steers the write", %{routine: routine, tmp: tmp} do
    path = Attachments.store!(routine, tmp, "../../../etc/passwd.png")

    assert Path.basename(path) =~ ~r/^[0-9a-f]{16}\.png$/
    refute path =~ ".."
  end

  test "an extension off the allowlist is stored as .png", %{routine: routine, tmp: tmp} do
    assert Path.extname(Attachments.store!(routine, tmp, "payload.exe")) == ".png"
    assert Path.extname(Attachments.store!(routine, tmp, "PHOTO.JPG")) == ".jpg"
  end

  test "the same content dropped twice is one file", %{routine: routine, tmp: tmp} do
    assert Attachments.store!(routine, tmp, "a.png") == Attachments.store!(routine, tmp, "b.png")
  end

  test "the agent is told where the image is and to read it first" do
    assert Attachments.compose("what is this", []) == "what is this"

    composed = Attachments.compose("  what is this ", ["/w/uploads/ab.png"])

    assert composed ==
             "what is this\nattached image: /w/uploads/ab.png -- Read it before answering"

    # an image alone is a message
    assert Attachments.compose("", ["/w/uploads/ab.png"]) =~ ~r/^attached image:/
  end
end
