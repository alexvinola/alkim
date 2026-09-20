defmodule AlkimWeb.Router do
  use AlkimWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlkimWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AlkimWeb do
    pipe_through :browser

    live "/", ProjectsLive
    live "/projects", ProjectsLive
    live "/projects/:id", ProjectLive
    live "/projects/:id/:tab", ProjectLive
    live "/sessions", SessionsLive
    live "/sessions/new", SessionNewLive
    live "/sessions/:id", SessionLive
    live "/workflows/new", WorkflowNewLive
    live "/workflows/:id", WorkflowLive
    live "/workflows/:id/:tab", WorkflowLive
    live "/providers", ProvidersLive
  end
end
