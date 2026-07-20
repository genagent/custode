defmodule CustodeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :custode

  @session_options [
    store: :cookie,
    key: "_custode_key",
    signing_salt: "custode-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # The LiveView client JS, served straight out of the hex packages.
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.Session, @session_options)
  plug(CustodeWeb.Router)
end
