defmodule CustodeWeb.FeedThumbnailsTest do
  @moduledoc """
  #180 slice 3: an image dropped on a prompt box shows up as a thumbnail in
  the feed, and the route that serves it reaches nothing but a routine's own
  uploads/ directory.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Custode.Uploads

  @endpoint CustodeWeb.Endpoint

  # the same 1x1 png the upload tests drop
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    routine = routine_fixture!(tmp_workspace!())
    %{conn: build_conn(), routine: routine, image: upload!(routine, "shot.png", @png)}
  end

  defp upload!(routine, name, content) do
    dir = Path.join(Path.expand(routine.workspace), "uploads")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp prompted(routine, text),
    do: %{"event" => "prompted", "agent" => routine.id, "prompt" => text}

  defp attached(path), do: "attached image: #{path} -- Read it before answering"

  describe "Custode.Uploads" do
    test "resolves a file inside the routine's own uploads/", %{routine: routine, image: image} do
      assert Uploads.path(routine.id, image) == {:ok, image}
      assert Uploads.path(routine.id, "shot.png") == {:ok, image}
      assert Uploads.url(routine.id, image) == "/agents/#{routine.id}/uploads/shot.png"
    end

    test "refuses everything outside it", %{routine: routine, image: image} do
      assert Uploads.path(routine.id, "../../../etc/passwd") == :error
      assert Uploads.path(routine.id, "../mix.exs") == :error
      assert Uploads.path(routine.id, "notes.txt") == :error
      assert Uploads.path(routine.id, "gone.png") == :error
      assert Uploads.path("no-such-routine", image) == :error
      assert Uploads.path(nil, image) == :error
      assert Uploads.url(routine.id, "gone.png") == nil
    end
  end

  describe "the upload route" do
    test "serves the image with its own content type", %{conn: conn, routine: routine} do
      conn = get(conn, "/agents/#{routine.id}/uploads/shot.png")

      assert conn.status == 200
      assert response_content_type(conn, :png) =~ "image/png"
      assert response(conn, 200) == @png
    end

    test "404s on a name that climbs, a name that is not an image, and a stranger",
         %{conn: conn, routine: routine} do
      # one path segment, %2F-encoded -- the shape a traversal actually takes
      assert get(conn, "/agents/#{routine.id}/uploads/..%2F..%2Fmix.exs").status == 404
      assert get(conn, "/agents/#{routine.id}/uploads/mix.exs").status == 404
      assert get(conn, "/agents/#{routine.id}/uploads/gone.png").status == 404
      assert get(conn, "/agents/nobody/uploads/shot.png").status == 404
    end
  end

  describe "thumbnails in the feed" do
    test "the prompt shows the picture, not the line addressed to the agent",
         %{routine: routine, image: image} do
      html =
        render_component(&CustodeWeb.Components.prompt_answer/1,
          entry: prompted(routine, "what is this?\n#{attached(image)}")
        )

      assert html =~ ~s(src="/agents/#{routine.id}/uploads/shot.png")
      assert html =~ "what is this?"
      refute html =~ "Read it before answering"
      refute html =~ attached(image)
    end

    test "an image-only prompt renders the thumbnail alone", %{routine: routine, image: image} do
      html =
        render_component(&CustodeWeb.Components.prompt_answer/1,
          entry: prompted(routine, attached(image))
        )

      assert html =~ ~s(src="/agents/#{routine.id}/uploads/shot.png")
      refute html =~ "attached image:"
    end

    test "an answer that carries an attachment gets one too", %{routine: routine, image: image} do
      html =
        render_component(&CustodeWeb.Components.prompt_answer/1,
          entry: %{
            "event" => "turn",
            "agent" => routine.id,
            "response" => "here it is\n#{attached(image)}"
          }
        )

      assert html =~ ~s(src="/agents/#{routine.id}/uploads/shot.png")
      assert html =~ "here it is"
      refute html =~ "Read it before answering"
    end

    test "a pruned upload leaves a filename chip, not a broken image",
         %{routine: routine} do
      gone = Path.join([Path.expand(routine.workspace), "uploads", "aged-out.png"])

      html =
        render_component(&CustodeWeb.Components.prompt_answer/1,
          entry: prompted(routine, "look at this\n#{attached(gone)}")
        )

      refute html =~ "<img"
      assert html =~ "aged-out.png"
      assert html =~ "look at this"
    end

    test "an ordinary prompt with no attachment renders exactly as before",
         %{routine: routine} do
      html =
        render_component(&CustodeWeb.Components.prompt_answer/1,
          entry: prompted(routine, "no pictures here")
        )

      assert html =~ "no pictures here"
      refute html =~ "<img"
    end
  end
end
