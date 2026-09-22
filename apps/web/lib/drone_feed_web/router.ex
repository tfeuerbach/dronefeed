defmodule DroneFeedWeb.Router do
  use DroneFeedWeb, :router

  import DroneFeedWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DroneFeedWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug DroneFeedWeb.Plugs.FrameHeaders
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug DroneFeedWeb.Plugs.ApiAuth
  end

  pipeline :stream_pull do
    plug :accepts, ["*/*"]
  end

  scope "/api", DroneFeedWeb do
    pipe_through :api

    post "/mediamtx/auth", MediaAuthController, :auth
  end

  scope "/api/v1", DroneFeedWeb.Api.V1 do
    pipe_through :api_auth

    get "/me", MeController, :show
    get "/feeds", FeedsController, :index
    get "/flights", FlightsController, :index
    get "/flights/:id", FlightsController, :show
    get "/live", LiveController, :index
    get "/live/:id", LiveController, :show
  end

  scope "/api", DroneFeedWeb do
    pipe_through :stream_pull

    get "/streams/vod/:id/metadata/:kind", MetadataController, :show
  end

  ## Authentication routes

  scope "/", DroneFeedWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{DroneFeedWeb.UserAuth, :require_authenticated}] do
      live "/flights", FlightLive.Index, :index
      live "/flights/public", FlightLive.Published, :index
      live "/flights/:id", FlightLive.Show, :show
      live "/live", LiveSessionLive.Index, :index
      live "/live/:id", LiveSessionLive.Show, :show
      live "/users/settings", UserLive.Settings, :edit
    end

    get "/flights/:id/media", FlightMediaController, :show
    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", DroneFeedWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    live_session :require_admin,
      on_mount: [
        {DroneFeedWeb.UserAuth, :require_authenticated},
        {DroneFeedWeb.UserAuth, :require_admin}
      ] do
      live "/admin", AdminLive.Index, :index
    end
  end

  scope "/", DroneFeedWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{DroneFeedWeb.UserAuth, :mount_current_scope}] do
      live "/", HomeLive, :index
      live "/users/log-in", UserLive.Login, :new
      live "/users/request-access", UserLive.RequestAccess, :new
      live "/users/verify/:token", UserLive.Verify, :confirm
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  if Application.compile_env(:drone_feed, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
