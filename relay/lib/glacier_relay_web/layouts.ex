defmodule GlacierRelayWeb.Layouts do
  @moduledoc """
  The root layout: the HTML skeleton around a LiveView, with the CSRF token the LiveView client
  needs and the prebuilt client libraries served from the dependencies.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Glacier Relay</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/live_view/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
