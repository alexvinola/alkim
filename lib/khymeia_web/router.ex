defmodule KhymeiaWeb.Router do
  use KhymeiaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KhymeiaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", KhymeiaWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/sessions/new", SessionNewLive
    live "/sessions/:id", SessionLive
    live "/workflows/new", WorkflowNewLive
    live "/workflows/:id", WorkflowLive
    live "/providers", ProvidersLive
  end
end
