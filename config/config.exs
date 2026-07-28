import Config

config :wajadi_engine,
  ecto_repos: [WajadiEngine.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :wajadi_engine, WajadiEngineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: WajadiEngineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WajadiEngine.PubSub,
  live_view: [signing_salt: "X+wOjjB2"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
