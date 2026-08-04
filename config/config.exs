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
  metadata: [
    :request_id,
    :auth_rows_cleared,
    :connect_on_init,
    :event,
    :failed,
    :key,
    :message,
    :message_id,
    :purged,
    :reason,
    :session_id,
    :session_row_id,
    :selected,
    :source,
    :started,
    :status,
    :skipped,
    :type
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :wajadi_engine, WajadiEngine.WhatsApp.SessionCleanupScheduler,
  enabled?: false,
  interval_ms: :timer.hours(24),
  batch_size: 100,
  run_on_start?: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
