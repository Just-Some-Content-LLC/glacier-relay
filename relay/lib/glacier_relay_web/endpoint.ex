defmodule GlacierRelayWeb.Endpoint do
  @moduledoc """
  The loopback HTTP endpoint (M3-A/M3-B). Bound to 127.0.0.1:4748 by configuration; a different
  port from the wire listener (127.0.0.1:4747) and never the same thing: the wire carries evidence
  in, this carries presentations out.

  Security assumptions (local development observability tool): no authentication; any local
  process that can reach the loopback port can read the mission report and summary. The LiveView
  socket accepts loopback origins only (`check_origin`) and requires the CSRF token the page
  carries. No write route, no uploads, no API. Static files are served read-only from the
  dependencies' prebuilt client (`phoenix.min.js`, `phoenix_live_view.min.js`) and this
  application's `priv/static` (`app.css`, `app.js`).
  """

  use Phoenix.Endpoint, otp_app: :glacier_relay

  @session_options [
    store: :cookie,
    key: "_glacier_relay_key",
    signing_salt: "glacier-relay-m3",
    same_site: "Lax"
  ]

  # The LiveView transport: WebSocket only (no long-poll); the session is needed for CSRF.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  # Prebuilt client libraries straight from the resolved dependencies (no Node, no bundler).
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Static, at: "/assets", from: :glacier_relay, only: ~w(app.css app.js)

  # Answers HEAD as GET without a body. No Plug.MethodOverride: a request's method is its method.
  plug Plug.Head

  plug Plug.Session, @session_options

  plug GlacierRelayWeb.Router
end
