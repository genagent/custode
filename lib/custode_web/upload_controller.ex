defmodule CustodeWeb.UploadController do
  @moduledoc """
  Serves one image out of a routine's workspace `uploads/` so the feed can
  show what the operator dropped (#180 slice 3).

  The route takes a routine id and a bare filename, never a path;
  `Custode.Uploads.path/2` owns the whole question of what is reachable, and
  anything it refuses is a 404 here. The route sits behind the dashboard's
  basic auth (#1) like every other page: an uploaded screenshot is as private
  as the feed entry that names it.
  """

  use Phoenix.Controller, formats: []

  def show(conn, %{"agent" => agent, "file" => file}) do
    case Custode.Uploads.path(agent, file) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(MIME.from_path(path))
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "")
    end
  end
end
