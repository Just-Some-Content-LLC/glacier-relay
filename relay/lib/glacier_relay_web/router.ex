defmodule GlacierRelayWeb.Router do
  @moduledoc """
  M3-A routes: two GET diagnostics that serve the existing read-only BEAM presentations as text.
  Every other method or path reaches `TextController.fallback/2`, which answers 405 or 404 without
  touching anything. The `:browser` pipeline (session, CSRF, secure headers) is defined for the
  future interactive routes and has no routes under it yet.
  """

  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :diagnostics do
    plug :put_secure_browser_headers
  end

  scope "/", GlacierRelayWeb do
    pipe_through :diagnostics

    get "/report.txt", TextController, :report
    get "/summary.txt", TextController, :summary
    match :*, "/*path", TextController, :fallback
  end
end
