defmodule GlacierRelayWeb.Router do
  @moduledoc """
  Routes: the two read-only LiveViews (`/`, `/report`) under the browser pipeline (session, CSRF,
  secure headers, root layout), the two GET text diagnostics, and a fallback that answers 405 or
  404 for everything else without touching anything.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GlacierRelayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :diagnostics do
    plug :put_secure_browser_headers
  end

  scope "/", GlacierRelayWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/report", ReportLive
  end

  scope "/", GlacierRelayWeb do
    pipe_through :diagnostics

    get "/report.txt", TextController, :report
    get "/summary.txt", TextController, :summary
    match :*, "/*path", TextController, :fallback
  end
end
