defmodule RiceWeb.Router do
  use RiceWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RiceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RiceWeb do
    pipe_through :browser

    get "/", PageController, :home

    # "Login with Semi" (OAuth 2.0 Authorization Code + PKCE).
    # /callback is the redirect_uri registered with the Semi OAuth app.
    get "/login", SemiAuthController, :login
    get "/callback", SemiAuthController, :callback
    get "/logout", SemiAuthController, :logout
  end

  # One-time session-handoff redemption for the front-end (cross-origin JSON,
  # CORS handled in the action). No session/CSRF pipeline needed.
  scope "/", RiceWeb do
    pipe_through :api

    get "/session/:ticket", SemiAuthController, :session
  end

  # Other scopes may use custom stacks.
  # scope "/api", RiceWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:rice, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RiceWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
