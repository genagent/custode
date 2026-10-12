defmodule Custode.Operator.AttachmentsTest do
  use ExUnit.Case, async: true

  import Custode.TestHelpers

  alias Custode.Operator.Attachments

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    workspace = tmp_workspace!()
    tmp = Path.join(System.tmp_dir!(), uid("upload"))
    File.write!(tmp, @png)
    on_exit(fn -> File.rm(tmp) end)
    %{routine: %{workspace: workspace}, tmp: tmp, workspace: workspace}
  end

  test "an image is stored in the routine's own uploads dir, under an absolute path",
       %{routine: routine, tmp: tmp, workspace: workspace} do
    path = Attachments.store!(routine, tmp, "screenshot.png")

    assert Path.type(path) == :absolute
    assert Path.dirname(path) == Path.join(Path.expand(workspace), "uploads")
    assert File.read!(path) == @png
  end

  # this is the code that writes an operator-supplied file to disk
  test "the client's filename never steers the write", %{routine: routine, tmp: tmp} do
    path = Attachments.store!(routine, tmp, "../../../etc/passwd.png")

    assert Path.basename(path) =~ ~r/^[0-9a-f]{64}\.png$/
    refute path =~ ".."
  end

  test "unknown extensions and declared formats that mismatch bytes are refused", %{
    routine: routine,
    tmp: tmp
  } do
    assert_raise ArgumentError, fn -> Attachments.store!(routine, tmp, "payload.exe") end
    assert_raise ArgumentError, fn -> Attachments.store!(routine, tmp, "PHOTO.JPG") end
    assert Path.extname(Attachments.store!(routine, tmp, "PHOTO.PNG")) == ".png"
  end

  test "a symlinked uploads directory cannot steer storage", %{routine: routine, tmp: tmp} do
    outside = tmp_workspace!()
    File.ln_s!(outside, Path.join(routine.workspace, "uploads"))
    assert_raise ArgumentError, fn -> Attachments.store!(routine, tmp, "a.png") end
    assert File.ls!(outside) == ["inbox"]
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
