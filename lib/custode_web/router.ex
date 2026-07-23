defmodule CustodeWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {CustodeWeb.Layouts, :root})
    plug(:maybe_basic_auth)
  end

  # An uploaded image is a binary response, so none of the HTML plumbing
  # applies -- but the auth guard does. A screenshot dropped on a prompt box
  # is as private as the feed entry that names it (#180 slice 3).
  pipeline :upload do
    plug(:maybe_basic_auth)
  end

  # #1: opt-in dashboard auth -- REQUIRED before any exposure beyond
  # loopback (#65's tailscale). Unset config keeps the localhost demo
  # frictionless; set config :custode, :dashboard_auth, username/password
  # to turn it on.
  def maybe_basic_auth(conn, _opts) do
    case Application.get_env(:custode, :dashboard_auth) do
      credentials when is_list(credentials) ->
        Plug.BasicAuth.basic_auth(conn, credentials)

      _off ->
        conn
    end
  end

  scope "/" do
    pipe_through(:browser)

    live("/", CustodeWeb.FleetLive)
    live("/repos", CustodeWeb.ReposLive)
    live("/suggestions", CustodeWeb.SuggestionsLive)
    live("/agents/:id", CustodeWeb.AgentLive)
    live("/feed", CustodeWeb.FeedLive)
    live("/metrics", CustodeWeb.MetricsLive)
  end

  scope "/" do
    pipe_through(:upload)

    get("/agents/:agent/uploads/:file", CustodeWeb.UploadController, :show)
  end
end
