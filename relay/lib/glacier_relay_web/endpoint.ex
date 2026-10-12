defmodule GlacierRelayWeb.Endpoint do
  @moduledoc """
  The loopback HTTP endpoint (M3-A). Bound to 127.0.0.1:4748 by configuration; a different port
  from the wire listener (127.0.0.1:4747) and never the same thing: the wire carries evidence in,
  this carries presentations out.

  Security assumptions (local development observability tool): no authentication; any local
  process that can reach the loopback port can read the mission report and summary. No write
  route, no uploads, no sockets, no static files and no LiveView are mounted in M3-A. The session
  cookie and CSRF protection exist for future interactive routes, not for the two text routes.
  """

  use Phoenix.Endpoint, otp_app: :glacier_relay

  # Answers HEAD as GET without a body. No Plug.MethodOverride: a request's method is its method.
  plug Plug.Head

  # Reserved for the future interactive routes (M3-B); the text routes do not touch the session.
  plug Plug.Session,
    store: :cookie,
    key: "_glacier_relay_key",
    signing_salt: "glacier-relay-m3",
    same_site: "Lax"

  plug GlacierRelayWeb.Router
end
