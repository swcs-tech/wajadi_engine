defmodule WajadiEngineWeb.Router do
  use WajadiEngineWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", WajadiEngineWeb do
    pipe_through :api

    scope "/whatsapp" do
      get "/account/:user_id/list", WhatsAppController, :list
      post "/account/:user_id/create", WhatsAppController, :create
      get "/account/:user_id/qr/:session_id/view", WhatsAppController, :get_qr
      get "/account/:user_id/qr/:session_id/refresh", WhatsAppController, :refresh_qr
      patch "/account/:user_id/connect/:session_id", WhatsAppController, :connect
      patch "/account/:user_id/disconnect/:session_id", WhatsAppController, :disconnect
      patch "/account/:user_id/pause/:session_id", WhatsAppController, :pause
      patch "/account/:user_id/resume/:session_id", WhatsAppController, :resume
      delete "/account/:user_id/logout/:session_id", WhatsAppController, :logout
      delete "/account/:user_id/delete/:session_id", WhatsAppController, :delete
    end
  end

  # Enable LiveDashboard
  if Application.compile_env(:wajadi_engine, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard",
        metrics: WajadiEngineWeb.Telemetry,
        ecto_repos: [WajadiEngine.Repo],
        ecto_psql_extras_options: [
          long_running_queries: [threshold: "200 milliseconds"]
        ]
    end

    scope "/dev/load", WajadiEngineWeb.Dev do
      pipe_through :api

      put "/whatsapp/sessions/:user_id/:session_id", LoadWhatsAppController, :upsert_session
      post "/whatsapp/messages/send", LoadWhatsAppController, :send_message
      post "/whatsapp/messages/receive", LoadWhatsAppController, :receive_message
      get "/whatsapp/sessions/:session_id/stats", LoadWhatsAppController, :session_stats
    end
  end
end
