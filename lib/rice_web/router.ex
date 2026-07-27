defmodule RiceWeb.Router do
  use RiceWeb, :router

  import RiceWeb.Api.Auth

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
    plug :fetch_current_user
  end

  pipeline :api_authenticated do
    plug :require_authenticated_user
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

  # 从 xiangjiandao-core 迁过来的业务接口。REST + HTTP 状态码,不套
  # core 那层 {code, message, data} 信封。见 docs/backend-migration-plan.md §4。
  scope "/api", RiceWeb.Api do
    pipe_through :api

    # 期 1:后台维护、C 端只读的内容位。无认证。
    get "/apps", AppController, :index
    get "/banners", BannerController, :index
    get "/announcements", AnnouncementController, :index
    get "/announcements/:id", AnnouncementController, :show
    get "/settings/foundation", SettingsController, :foundation

    # 期 2:附件读取(公开)。上传在下面的认证段里。
    get "/attachments/:id", AttachmentController, :show

    # 期 3:注册 / 登录。这几个必须匿名可用。
    post "/verification_codes", VerificationCodeController, :create
    post "/registrations/verification", RegistrationController, :verify
    post "/registrations", RegistrationController, :create
    post "/session", SessionController, :create
    post "/passwords/reset", PasswordController, :create

    # 期 4:节点、勋章与发放记录(公开可读)
    get "/nodes", NodeController, :index

    # 某人的勋章墙。:user_id 认 "me" / rice id / DID / handle。
    get "/users/:user_id/badges", BadgeController, :index
    get "/nodes/members", NodeController, :members
    get "/grain_grants", GrainGrantController, :index

    # 期 5:提案。列表和详情公开可读,写操作在下面的认证段。
    get "/proposals", ProposalController, :index
    get "/proposals/:id", ProposalController, :show
    get "/proposals/:proposal_id/comments", ProposalCommentController, :index
  end

  # 需要登录的接口
  scope "/api", RiceWeb.Api do
    pipe_through [:api, :api_authenticated]

    delete "/session", SessionController, :delete

    get "/users/me", UserController, :me
    patch "/users/me", UserController, :update
    delete "/users/me", UserController, :delete
    put "/users/me/phone", UserController, :update_phone
    put "/users/me/email", UserController, :update_email

    # 期 4:稻米。明细只能看自己的,转账当然要登录。
    get "/grain_transfers", GrainTransferController, :index
    post "/grain_transfers", GrainTransferController, :create

    # 期 5:提案的写操作
    post "/proposals", ProposalController, :create
    delete "/proposals/:id", ProposalController, :delete
    get "/proposals/:proposal_id/vote", ProposalVoteController, :show
    post "/proposals/:proposal_id/vote", ProposalVoteController, :create
    post "/proposals/:proposal_id/comments", ProposalCommentController, :create
    delete "/proposals/:proposal_id/comments/:id", ProposalCommentController, :delete

    # core 的 /file/upload 是匿名的;这里必须登录
    post "/attachments", AttachmentController, :create
  end

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
